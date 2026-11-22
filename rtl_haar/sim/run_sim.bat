@echo off
rem run_sim.bat: haar_engine.v testbench (vectors from sw/tools/haar_vectors.py)
rem   run in rtl_haar\sim:  run_sim.bat   -> prints PASS / FAIL
set VIV=C:\AMDDesignTools\2026.1\Vivado\bin
copy /y ..\haar_weak.mem . >nul
copy /y ..\haar_stage.mem . >nul
call %VIV%\xvlog.bat -i .. ..\haar_engine.v tb_haar.v || exit /b 1
call %VIV%\xelab.bat -debug off tb_haar -s tb_haar_sim || exit /b 1
call %VIV%\xsim.bat tb_haar_sim -R
