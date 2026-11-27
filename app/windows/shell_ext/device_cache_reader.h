#pragma once

#include <string>
#include <vector>

struct CachedDevice {
  std::wstring fingerprint;
  std::wstring alias;
  std::wstring ip;
  int port = 53317;
  bool https = true;
  bool online = false;
  bool favorite = false;
};

struct DeviceCacheData {
  std::wstring exe_path;
  std::vector<CachedDevice> devices;
};

std::wstring Utf8ToWide(const std::string& utf8);
std::wstring GetDefaultDeviceCachePath();
DeviceCacheData LoadDeviceCacheFromJson(const std::string& utf8_json);
DeviceCacheData LoadDeviceCacheFromFile(const std::wstring& path);
std::wstring QuoteWindowsArg(const std::wstring& arg);
std::wstring BuildSendCommandLine(const std::wstring& exe_path,
                                  const std::wstring& fingerprint,
                                  const std::vector<std::wstring>& paths);
