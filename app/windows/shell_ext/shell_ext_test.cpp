#include <windows.h>
#include <objbase.h>
#include <shobjidl_core.h>

#include <cstdio>
#include <string>
#include <vector>

#include "device_cache_reader.h"

namespace {

// {7E4B2F91-6C3A-4D88-9F12-3A8D5E71B402}
const CLSID CLSID_LanDropExplorerCommand = {
    0x7e4b2f91,
    0x6c3a,
    0x4d88,
    {0x9f, 0x12, 0x3a, 0x8d, 0x5e, 0x71, 0xb4, 0x02}};

bool AssertTrue(bool cond, const char* msg) {
  if (!cond) {
    std::printf("FAIL: %s\n", msg);
    return false;
  }
  return true;
}

std::wstring GetDllPathNextToSelf() {
  wchar_t buf[MAX_PATH] = {};
  DWORD len = ::GetModuleFileNameW(nullptr, buf, MAX_PATH);
  std::wstring self(buf, len);
  size_t slash = self.find_last_of(L"\\/");
  return self.substr(0, slash + 1) + L"landrop_shell_ext.dll";
}

}  // namespace

int wmain() {
  // 1. Test JSON parsing
  const std::string json =
      R"({"exePath":"E:\\CodeBase\\localsend-fork\\landrop.exe","devices":[)"
      R"({"fingerprint":"FP1","alias":"Honor \u00586","ip":"192.168.1.5","port":53317,"https":true,"online":true,"favorite":true},)"
      R"({"fingerprint":"FP2","alias":"Backup Phone","ip":"192.168.1.6","port":53317,"https":true,"online":false,"favorite":true}]})";

  DeviceCacheData parsed = LoadDeviceCacheFromJson(json);
  if (!AssertTrue(parsed.exe_path == L"E:\\CodeBase\\localsend-fork\\landrop.exe",
                  "exePath parsed")) {
    return 1;
  }
  if (!AssertTrue(parsed.devices.size() == 2, "two devices parsed")) {
    return 1;
  }
  if (!AssertTrue(parsed.devices[0].alias == L"Honor X6" &&
                      parsed.devices[0].online &&
                      parsed.devices[0].fingerprint == L"FP1",
                  "first device fields")) {
    return 1;
  }
  if (!AssertTrue(parsed.devices[1].alias == L"Backup Phone" &&
                      !parsed.devices[1].online &&
                      parsed.devices[1].fingerprint == L"FP2",
                  "second device fields")) {
    return 1;
  }

  // 2. Test command line quoting (spaces + trailing backslash)
  std::wstring cmd = BuildSendCommandLine(
      L"C:\\Program Files\\LanDrop\\landrop.exe", L"FP1",
      {L"C:\\Users\\JAKE\\My Folder\\", L"C:\\a.txt"});
  std::wstring expected =
      L"\"C:\\Program Files\\LanDrop\\landrop.exe\" --hidden --send-to FP1 "
      L"\"C:\\Users\\JAKE\\My Folder\\\\\" C:\\a.txt";
  if (!AssertTrue(cmd == expected, "BuildSendCommandLine quoting")) {
    return 1;
  }

  // 3. Test COM DLL loading + EnumSubCommands against temp USERPROFILE
  wchar_t temp_dir[MAX_PATH] = {};
  ::GetTempPathW(MAX_PATH, temp_dir);
  std::wstring fake_profile = std::wstring(temp_dir) + L"landrop_shell_test_profile";
  std::wstring landrop_dir = fake_profile + L"\\.landrop";
  ::CreateDirectoryW(fake_profile.c_str(), nullptr);
  ::CreateDirectoryW(landrop_dir.c_str(), nullptr);
  std::wstring devices_path = landrop_dir + L"\\devices.json";

  HANDLE hFile = ::CreateFileW(devices_path.c_str(), GENERIC_WRITE, 0, nullptr,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (!AssertTrue(hFile != INVALID_HANDLE_VALUE, "create temp devices.json")) {
    return 1;
  }
  DWORD written = 0;
  ::WriteFile(hFile, json.data(), static_cast<DWORD>(json.size()), &written,
              nullptr);
  ::CloseHandle(hFile);
  ::SetEnvironmentVariableW(L"USERPROFILE", fake_profile.c_str());
  ::SetEnvironmentVariableW(L"APPDATA", fake_profile.c_str());

  std::wstring dll_path = GetDllPathNextToSelf();
  HMODULE mod = ::LoadLibraryW(dll_path.c_str());
  if (!AssertTrue(mod != nullptr, "LoadLibraryW(landrop_shell_ext.dll)")) {
    return 1;
  }

  using DllGetClassObjectFn = HRESULT(STDAPICALLTYPE*)(REFCLSID, REFIID, LPVOID*);
  auto get_class_obj = reinterpret_cast<DllGetClassObjectFn>(
      ::GetProcAddress(mod, "DllGetClassObject"));
  if (!AssertTrue(get_class_obj != nullptr, "GetProcAddress(DllGetClassObject)")) {
    return 1;
  }

  IClassFactory* factory = nullptr;
  HRESULT hr = get_class_obj(CLSID_LanDropExplorerCommand, IID_IClassFactory,
                             reinterpret_cast<void**>(&factory));
  if (!AssertTrue(SUCCEEDED(hr) && factory != nullptr, "DllGetClassObject")) {
    return 1;
  }

  IExplorerCommand* root = nullptr;
  hr = factory->CreateInstance(nullptr, IID_IExplorerCommand,
                               reinterpret_cast<void**>(&root));
  factory->Release();
  if (!AssertTrue(SUCCEEDED(hr) && root != nullptr, "CreateInstance(IExplorerCommand)")) {
    return 1;
  }

  LPWSTR root_title = nullptr;
  hr = root->GetTitle(nullptr, &root_title);
  if (!AssertTrue(SUCCEEDED(hr) && root_title != nullptr &&
                      std::wstring(root_title) == L"LanDrop",
                  "root title == LanDrop")) {
    return 1;
  }
  ::CoTaskMemFree(root_title);

  EXPCMDFLAGS flags = ECF_DEFAULT;
  hr = root->GetFlags(&flags);
  if (!AssertTrue(SUCCEEDED(hr) && (flags & ECF_HASSUBCOMMANDS) != 0,
                  "root flags has ECF_HASSUBCOMMANDS")) {
    return 1;
  }

  IEnumExplorerCommand* enum_cmds = nullptr;
  hr = root->EnumSubCommands(&enum_cmds);
  if (!AssertTrue(SUCCEEDED(hr) && enum_cmds != nullptr, "EnumSubCommands")) {
    return 1;
  }

  std::vector<std::wstring> sub_titles;
  IExplorerCommand* sub = nullptr;
  ULONG fetched = 0;
  while (enum_cmds->Next(1, &sub, &fetched) == S_OK && fetched == 1 &&
         sub != nullptr) {
    LPWSTR title = nullptr;
    if (SUCCEEDED(sub->GetTitle(nullptr, &title)) && title != nullptr) {
      sub_titles.emplace_back(title);
      ::CoTaskMemFree(title);
    }
    sub->Release();
    sub = nullptr;
  }
  enum_cmds->Release();
  root->Release();

  if (!AssertTrue(sub_titles.size() == 2 &&
                      sub_titles[0] == L"Honor X6" &&
                      sub_titles[1] == L"Backup Phone (offline)",
                  "EnumSubCommands titles match")) {
    return 1;
  }

  ::DeleteFileW(devices_path.c_str());
  ::RemoveDirectoryW(landrop_dir.c_str());
  ::RemoveDirectoryW(fake_profile.c_str());
  ::FreeLibrary(mod);

  std::printf("ALL SHELL_EXT TESTS PASSED\n");
  return 0;
}
