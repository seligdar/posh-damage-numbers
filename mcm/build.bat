@echo off
rem Generates the MCM plugin source and the Lua settings module from mcm\spec.py and lang\*.txt,
rem compiles the plugin with Visual Studio 2022 and puts both into ..\mod\DamageNumbers.
rem MCM_SDK is the folder with ModConfigMenu.h: the sdk folder of the Mod Config Menu Workshop item.
setlocal
if "%MCM_SDK%"=="" set "MCM_SDK=C:\Program Files (x86)\Steam\steamapps\workshop\content\233860\3813761584\sdk"
if not exist "%MCM_SDK%\ModConfigMenu.h" goto nosdk
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0"
python gen_mcm.py out || exit /b 1
cd out
cl /nologo /LD /MT /O2 /W4 /utf-8 /EHsc /I"%MCM_SDK%" PoshDamageNumbersMCM.cpp /Fe:PoshDamageNumbersMCM.dll /link /NOLOGO kernel32.lib || exit /b 1
dumpbin /nologo /exports PoshDamageNumbersMCM.dll | findstr /R "MCM_Describe Posh_ startPlugin"
copy /y PoshDamageNumbersMCM.dll ..\..\mod\DamageNumbers\ >nul || exit /b 1
copy /y dn_settings.lua ..\..\mod\DamageNumbers\scripts\ >nul || exit /b 1
echo built and copied into mod\DamageNumbers
exit /b 0
:nosdk
echo ModConfigMenu.h not found in "%MCM_SDK%". Set MCM_SDK to the sdk folder of Mod Config Menu.
exit /b 1
