#!/usr/bin/env python3
# =============================================================================
# build_fw.py: build the MicroBlaze-V firmware (stage 3: HTTP server)
#
#   Run (from PowerShell, in the repository root):
#     cmd /c "chcp 65001 >nul && C:\AMDDesignTools\2026.1\Vitis\bin\vitis.bat -s sw\build_fw.py"
#   * Vitis on Windows set to the Japanese code page fails in create_client with
#     a UTF-8 decode error, so switch the code page to UTF-8 with chcp 65001 first
#
#   Input : firmware/vga_top.xsa (exported from Vivado with sw/export_xsa.tcl)
#   Output: firmware/vga_web/build/vga_web.elf
#
#   What it does (re-creates the platform and app every time, regardless of current state)
#     1. Create a local copy of lwip220 (see below)
#     2. Platform vga_plat: microblaze_riscv_0 / standalone + lwip220 (RAW API)
#     3. App vga_web: start from the lwip_echo_server template (platform / lwIP init), then overwrite it with sw/src
#          main.c        : PHY check, progress output
#          platform.c    : link-detect guard
#          http_server.c : HTTP server (/ and /frame.bmp), replaces the template echo.c
#        Place it in DDR3 at 0x8100_0000 and above (0x8000_0000 and above holds the camera frame buffer)
#
#   Workaround for the lwip220 BOM: in the Vitis 2026.1 bundled
#   ThirdParty/sw_services/lwip220_v1_4/data/lwip220.yaml has a UTF-8 BOM at the start,
#   so the repository scan does not see lwip220 and set_lib('lwip220') fails
#   ("not valid for the given processor"). Copy it to firmware/sw_repo with the BOM
#   removed and register it as a local software repository
#   (the install directory is not modified).
# =============================================================================
import os
import shutil
import vitis

ROOT    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS      = os.path.join(ROOT, 'firmware')
XSA     = os.path.join(WS, 'vga_top.xsa')
PLAT    = 'vga_plat'
DOMAIN  = 'standalone_mbv'
CPU     = 'microblaze_riscv_0'
APP     = 'vga_web'
OLD_APPS = ['eth_echo']   # stage 2 app name (delete if left over)
VITIS   = os.environ.get('XILINX_VITIS', r'C:\AMDDesignTools\2026.1\Vitis')
LWIP    = 'lwip220_v1_4'

DDR_REGION = 'fb_test_mig_7series_1_0_memory_0'
DDR_BASE   = '0x81000000'   # 0x8000_0000 to +16 MB is reserved for frame buffers (8 x 1 MB, see sw/src/frame.c)
DDR_SIZE   = '0x7000000'    # up to 0x87FF_FFFF

LWIP_CFG = {
    'lwip220_api_mode'                 : 'RAW_API',
    'lwip220_dhcp'                     : 'true',    # use DHCP (fixed 192.168.1.10 on timeout)
    'lwip220_lwip_dhcp_does_acd_check' : 'true',
    'lwip220_ipv6_enable'              : 'false',
    'lwip220_pbuf_pool_size'           : '2048',
    'lwip220_tcp_wnd'                  : '8192',
    'lwip220_tcp_snd_buf'              : '65535',   # send buffer for images (max without window scaling)
    'lwip220_memp_n_tcp_seg'           : '1024',    # >= TCP_SND_QUEUELEN (16 * snd_buf / MSS = 718)
    'lwip220_mem_size'                 : '262144',
    'lwip220_memp_n_pbuf'              : '1024',    # 1 per segment sent without COPY (image data)
}

# Code is placed above 2 GB (0x8100_0000), so use medany (from the Vitis warning)
EXTRA_CFLAGS = '-mcmodel=medany'


def prepare_sw_repo():
    src = os.path.join(VITIS, 'data', 'embeddedsw', 'ThirdParty', 'sw_services', LWIP)
    dst = os.path.join(WS, 'sw_repo', 'ThirdParty', 'sw_services', LWIP)
    if not os.path.isdir(dst):
        shutil.copytree(src, dst)
    y = os.path.join(dst, 'data', 'lwip220.yaml')
    with open(y, 'rb') as f:
        b = f.read()
    if b.startswith(b'\xef\xbb\xbf'):
        with open(y, 'wb') as f:
            f.write(b[3:])
    return os.path.join(WS, 'sw_repo')


def try_delete(client, name):
    try:
        client.delete_component(name)
        print(f'deleted component {name}')
    except Exception:
        pass
    # Delete the folder too if it was left unregistered in the workspace (both are generated output)
    d = os.path.join(WS, name)
    if os.path.isdir(d):
        shutil.rmtree(d)
        print(f'removed {d}')


def main():
    if not os.path.isfile(XSA):
        raise SystemExit(f'XSA not found: {XSA} (export it first with sw/export_xsa.tcl)')
    repo = prepare_sw_repo()

    client = vitis.create_client()
    try:
        try:
            client.set_workspace(WS)
        except Exception as e:
            if 'update_workspace' not in str(e):
                raise
            client.update_workspace(WS)      # workspace from an older version
            client.set_workspace(WS)
        client.set_embedded_sw_repo(level='LOCAL', path=repo)

        for name in [APP] + OLD_APPS:
            try_delete(client, name)
        try_delete(client, PLAT)

        # ── Platform ──
        plat = client.create_platform_component(name=PLAT, hw_design=XSA, cpu=CPU,
                                                os='standalone', domain_name=DOMAIN)
        dom = plat.get_domain(DOMAIN)
        dom.set_lib('lwip220')
        for k, v in LWIP_CFG.items():
            dom.set_config('lib', k, v, 'lwip220')
        dom.set_config('lib', 'XILTIMER_en_interval_timer', 'true', 'xiltimer')
        dom.set_config('lib', 'XILTIMER_tick_timer', 'axi_timer_0', 'xiltimer')
        dom.set_config('os', 'standalone_stdout', 'axi_uartlite_0')
        dom.set_config('os', 'standalone_stdin', 'axi_uartlite_0')
        flags = dom.get_config('proc', 'proc_extra_compiler_flags')
        if isinstance(flags, dict):
            flags = flags.get('value', '')
        flags = str(flags or '')
        if EXTRA_CFLAGS not in flags:
            dom.set_config('proc', 'proc_extra_compiler_flags', (flags + ' ' + EXTRA_CFLAGS).strip())
        plat.build()

        # ── Application ──
        xpfm = client.find_platform_in_repos(PLAT)
        app = client.create_app_component(name=APP, platform=xpfm, domain=DOMAIN,
                                          template='lwip_echo_server')
        ld = app.get_ld_script()
        ld.update_memory_region(name=DDR_REGION, base_address=DDR_BASE, size=DDR_SIZE)
        ld.set_stack_size('0x10000')
        ld.set_heap_size('0x100000')
        app.set_app_config(key='USER_COMPILE_OPTIMIZATION_LEVEL', values=['-O2'])
        app.set_app_config(key='USER_COMPILE_OTHER_FLAGS', values=[EXTRA_CFLAGS])
        # Overwrite the template files with our own sources (sw/src)
        src_dir = os.path.join(ROOT, 'sw', 'src')
        for fn in sorted(os.listdir(src_dir)):
            shutil.copyfile(os.path.join(src_dir, fn), os.path.join(WS, APP, 'src', fn))
            print(f'override src/{fn}')
        # Swap the template echo.c for our extra sources (CMakeLists lists the sources by name)
        app_src = os.path.join(WS, APP, 'src')
        os.remove(os.path.join(app_src, 'echo.c'))
        cm = os.path.join(app_src, 'CMakeLists.txt')
        with open(cm, encoding='utf-8') as f:
            t = f.read()
        if 'collect (PROJECT_LIB_SOURCES echo.c)' not in t:
            raise SystemExit('CMakeLists.txt: echo.c entry not found')
        with open(cm, 'w', encoding='utf-8') as f:
            extra = [fn for fn in sorted(os.listdir(src_dir))
                     if fn.endswith('.c') and fn not in ('main.c', 'platform.c')]
            f.write(t.replace('collect (PROJECT_LIB_SOURCES echo.c)',
                              '\n'.join(f'collect (PROJECT_LIB_SOURCES {fn})' for fn in extra)))
        app.build()
        print('ELF:', os.path.join(WS, APP, 'build', APP + '.elf'))
    finally:
        vitis.dispose()


if __name__ == '__main__':
    main()
