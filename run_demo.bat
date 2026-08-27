@echo off
chcp 65001 >nul
REM Clip sense 부스 데모 실행기 (Windows) - 크래시 시 자동 재시작.
REM chcp 65001: 콘솔을 UTF-8로 전환해 한글 안내가 안 깨지게 한다.
REM
REM 사용법:
REM   run_demo.bat                  웹캠(카메라 0), 저장된 ROI 사용
REM   run_demo.bat --reselect-roi   ROI 다시 지정하고 시작
REM   set CAM=1 ^&^& run_demo.bat    다른 카메라 인덱스
REM   run_demo.bat --video data\reference.mp4   영상 파일로 (리허설)

cd /d "%~dp0"

set PY=.venv\Scripts\python.exe
if not exist "%PY%" set PY=python

if "%CAM%"=="" set CAM=0

echo Clip sense 데모 시작 (종료: 디버그 창에서 q 또는 ESC)

set FAST_FAILS=0

:loop
set START=%TIME%
echo %* | findstr /C:"--video" /C:"--camera" >nul
if %errorlevel%==0 (
    "%PY%" main.py %*
) else (
    "%PY%" main.py --camera %CAM% %*
)
set CODE=%errorlevel%

if %CODE%==0 (
    echo 정상 종료했습니다.
    goto end
)
if %CODE%==2 (
    echo.
    echo !! 설정 오류로 종료했습니다 ^(위 메시지 참고^). 재시작하지 않습니다.
    echo    ROI를 다시 잡으려면: run_demo.bat --reselect-roi
    pause
    exit /b 2
)
echo.
echo !! 예기치 못한 종료 ^(코드 %CODE%^). 2초 후 재시작합니다...
echo    계속 반복되면 이 창을 닫고 README의 문제 해결을 보세요.
timeout /t 2 /nobreak >nul
goto loop

:end
echo.
pause
exit /b 0
