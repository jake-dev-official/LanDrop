#include "device_cache_reader.h"

#include <windows.h>

#include <cctype>
#include <cstdint>
#include <fstream>
#include <sstream>

namespace {

void SkipWhitespace(const std::string& s, size_t& pos) {
  while (pos < s.size() &&
         (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\r' || s[pos] == '\n')) {
    ++pos;
  }
}

void AppendUtf8CodePoint(std::string& out, uint32_t cp) {
  if (cp <= 0x7F) {
    out.push_back(static_cast<char>(cp));
  } else if (cp <= 0x7FF) {
    out.push_back(static_cast<char>(0xC0 | ((cp >> 6) & 0x1F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp <= 0xFFFF) {
    out.push_back(static_cast<char>(0xE0 | ((cp >> 12) & 0x0F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp <= 0x10FFFF) {
    out.push_back(static_cast<char>(0xF0 | ((cp >> 18) & 0x07)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

bool ParseHex4(const std::string& s, size_t& pos, uint32_t& out_val) {
  if (pos + 4 > s.size()) {
    return false;
  }
  uint32_t v = 0;
  for (int i = 0; i < 4; ++i) {
    char c = s[pos + static_cast<size_t>(i)];
    v <<= 4;
    if (c >= '0' && c <= '9') {
      v |= static_cast<uint32_t>(c - '0');
    } else if (c >= 'a' && c <= 'f') {
      v |= static_cast<uint32_t>(c - 'a' + 10);
    } else if (c >= 'A' && c <= 'F') {
      v |= static_cast<uint32_t>(c - 'A' + 10);
    } else {
      return false;
    }
  }
  pos += 4;
  out_val = v;
  return true;
}

bool ParseJsonString(const std::string& s, size_t& pos, std::string& out) {
  SkipWhitespace(s, pos);
  if (pos >= s.size() || s[pos] != '"') {
    return false;
  }
  ++pos;
  out.clear();

  while (pos < s.size()) {
    char c = s[pos++];
    if (c == '"') {
      return true;
    }
    if (c == '\\') {
      if (pos >= s.size()) {
        return false;
      }
      char esc = s[pos++];
      switch (esc) {
        case '"':
          out.push_back('"');
          break;
        case '\\':
          out.push_back('\\');
          break;
        case '/':
          out.push_back('/');
          break;
        case 'b':
          out.push_back('\b');
          break;
        case 'f':
          out.push_back('\f');
          break;
        case 'n':
          out.push_back('\n');
          break;
        case 'r':
          out.push_back('\r');
          break;
        case 't':
          out.push_back('\t');
          break;
        case 'u': {
          uint32_t cp = 0;
          if (!ParseHex4(s, pos, cp)) {
            return false;
          }
          if (cp >= 0xD800 && cp <= 0xDBFF && pos + 2 <= s.size() &&
              s[pos] == '\\' && s[pos + 1] == 'u') {
            size_t saved = pos;
            pos += 2;
            uint32_t low = 0;
            if (ParseHex4(s, pos, low) && low >= 0xDC00 && low <= 0xDFFF) {
              cp = 0x10000 + (((cp - 0xD800) << 10) | (low - 0xDC00));
            } else {
              pos = saved;
            }
          }
          AppendUtf8CodePoint(out, cp);
          break;
        }
        default:
          out.push_back(esc);
          break;
      }
    } else {
      out.push_back(c);
    }
  }
  return false;
}

bool SkipJsonValue(const std::string& s, size_t& pos);

bool SkipJsonArrayOrObject(const std::string& s, size_t& pos, char open_ch,
                           char close_ch) {
  if (pos >= s.size() || s[pos] != open_ch) {
    return false;
  }
  ++pos;
  while (pos < s.size()) {
    SkipWhitespace(s, pos);
    if (pos >= s.size()) {
      return false;
    }
    if (s[pos] == close_ch) {
      ++pos;
      return true;
    }
    if (open_ch == '{') {
      std::string dummy_key;
      if (!ParseJsonString(s, pos, dummy_key)) {
        return false;
      }
      SkipWhitespace(s, pos);
      if (pos >= s.size() || s[pos] != ':') {
        return false;
      }
      ++pos;
    }
    if (!SkipJsonValue(s, pos)) {
      return false;
    }
    SkipWhitespace(s, pos);
    if (pos < s.size() && s[pos] == ',') {
      ++pos;
    }
  }
  return false;
}

bool SkipJsonValue(const std::string& s, size_t& pos) {
  SkipWhitespace(s, pos);
  if (pos >= s.size()) {
    return false;
  }
  char c = s[pos];
  if (c == '"') {
    std::string dummy;
    return ParseJsonString(s, pos, dummy);
  }
  if (c == '{') {
    return SkipJsonArrayOrObject(s, pos, '{', '}');
  }
  if (c == '[') {
    return SkipJsonArrayOrObject(s, pos, '[', ']');
  }
  while (pos < s.size()) {
    char ch = s[pos];
    if (ch == ',' || ch == '}' || ch == ']' || ch == ' ' || ch == '\t' ||
        ch == '\r' || ch == '\n') {
      return true;
    }
    ++pos;
  }
  return true;
}

bool ParseJsonBool(const std::string& s, size_t& pos, bool& out) {
  SkipWhitespace(s, pos);
  if (s.compare(pos, 4, "true") == 0) {
    pos += 4;
    out = true;
    return true;
  }
  if (s.compare(pos, 5, "false") == 0) {
    pos += 5;
    out = false;
    return true;
  }
  return SkipJsonValue(s, pos) && false;
}

bool ParseJsonInt(const std::string& s, size_t& pos, int& out) {
  SkipWhitespace(s, pos);
  size_t start = pos;
  if (pos < s.size() && (s[pos] == '-' || s[pos] == '+')) {
    ++pos;
  }
  while (pos < s.size() &&
         std::isdigit(static_cast<unsigned char>(s[pos])) != 0) {
    ++pos;
  }
  if (pos == start) {
    return false;
  }
  int val = 0;
  bool neg = (s[start] == '-');
  size_t idx = (s[start] == '-' || s[start] == '+') ? start + 1 : start;
  for (; idx < pos; ++idx) {
    val = val * 10 + (s[idx] - '0');
  }
  out = neg ? -val : val;
  return true;
}

bool ParseDeviceObject(const std::string& s, size_t& pos, CachedDevice& dev) {
  SkipWhitespace(s, pos);
  if (pos >= s.size() || s[pos] != '{') {
    return false;
  }
  ++pos;

  while (pos < s.size()) {
    SkipWhitespace(s, pos);
    if (pos >= s.size()) {
      return false;
    }
    if (s[pos] == '}') {
      ++pos;
      return true;
    }

    std::string key;
    if (!ParseJsonString(s, pos, key)) {
      return false;
    }
    SkipWhitespace(s, pos);
    if (pos >= s.size() || s[pos] != ':') {
      return false;
    }
    ++pos;
    SkipWhitespace(s, pos);

    if (key == "fingerprint") {
      std::string v;
      if (!ParseJsonString(s, pos, v)) return false;
      dev.fingerprint = Utf8ToWide(v);
    } else if (key == "alias") {
      std::string v;
      if (!ParseJsonString(s, pos, v)) return false;
      dev.alias = Utf8ToWide(v);
    } else if (key == "ip") {
      std::string v;
      if (!ParseJsonString(s, pos, v)) return false;
      dev.ip = Utf8ToWide(v);
    } else if (key == "port") {
      if (!ParseJsonInt(s, pos, dev.port)) return false;
    } else if (key == "https") {
      if (!ParseJsonBool(s, pos, dev.https)) return false;
    } else if (key == "online") {
      if (!ParseJsonBool(s, pos, dev.online)) return false;
    } else if (key == "favorite") {
      if (!ParseJsonBool(s, pos, dev.favorite)) return false;
    } else {
      if (!SkipJsonValue(s, pos)) return false;
    }

    SkipWhitespace(s, pos);
    if (pos < s.size() && s[pos] == ',') {
      ++pos;
    }
  }
  return false;
}

}  // namespace

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return L"";
  }
  int len = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                  static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) {
    return L"";
  }
  std::wstring wide(static_cast<size_t>(len), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), len);
  return wide;
}

std::wstring GetDefaultDeviceCachePath() {
  auto read_env = [](const wchar_t* name) -> std::wstring {
    DWORD required = ::GetEnvironmentVariableW(name, nullptr, 0);
    if (required == 0) {
      return L"";
    }
    std::wstring value(static_cast<size_t>(required), L'\0');
    DWORD written = ::GetEnvironmentVariableW(name, value.data(), required);
    if (written == 0 || written >= required) {
      return L"";
    }
    value.resize(static_cast<size_t>(written));
    return value;
  };

  auto exists = [](const std::wstring& path) -> bool {
    if (path.empty()) {
      return false;
    }
    DWORD attrs = ::GetFileAttributesW(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES &&
           (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
  };

  const std::wstring user_profile = read_env(L"USERPROFILE");
  const std::wstring user_path =
      user_profile.empty() ? L"" : (user_profile + L"\\.landrop\\devices.json");
  const std::wstring appdata = read_env(L"APPDATA");
  const std::wstring appdata_path =
      appdata.empty() ? L"" : (appdata + L"\\LanDrop\\devices.json");

  if (exists(user_path)) {
    return user_path;
  }
  if (exists(appdata_path)) {
    return appdata_path;
  }
  return !user_path.empty() ? user_path : appdata_path;
}

DeviceCacheData LoadDeviceCacheFromJson(const std::string& utf8_json) {
  DeviceCacheData data;
  size_t pos = 0;
  SkipWhitespace(utf8_json, pos);
  if (pos >= utf8_json.size() || utf8_json[pos] != '{') {
    return data;
  }
  ++pos;

  while (pos < utf8_json.size()) {
    SkipWhitespace(utf8_json, pos);
    if (pos >= utf8_json.size() || utf8_json[pos] == '}') {
      break;
    }
    std::string key;
    if (!ParseJsonString(utf8_json, pos, key)) {
      break;
    }
    SkipWhitespace(utf8_json, pos);
    if (pos >= utf8_json.size() || utf8_json[pos] != ':') {
      break;
    }
    ++pos;
    SkipWhitespace(utf8_json, pos);

    if (key == "exePath") {
      std::string exe_utf8;
      if (!ParseJsonString(utf8_json, pos, exe_utf8)) {
        break;
      }
      data.exe_path = Utf8ToWide(exe_utf8);
    } else if (key == "devices") {
      if (pos >= utf8_json.size() || utf8_json[pos] != '[') {
        break;
      }
      ++pos;
      while (pos < utf8_json.size()) {
        SkipWhitespace(utf8_json, pos);
        if (pos >= utf8_json.size()) {
          break;
        }
        if (utf8_json[pos] == ']') {
          ++pos;
          break;
        }
        CachedDevice dev;
        if (!ParseDeviceObject(utf8_json, pos, dev)) {
          break;
        }
        if (!dev.fingerprint.empty() && !dev.alias.empty()) {
          data.devices.push_back(std::move(dev));
        }
        SkipWhitespace(utf8_json, pos);
        if (pos < utf8_json.size() && utf8_json[pos] == ',') {
          ++pos;
        }
      }
    } else {
      if (!SkipJsonValue(utf8_json, pos)) {
        break;
      }
    }

    SkipWhitespace(utf8_json, pos);
    if (pos < utf8_json.size() && utf8_json[pos] == ',') {
      ++pos;
    }
  }

  return data;
}

DeviceCacheData LoadDeviceCacheFromFile(const std::wstring& path) {
  if (path.empty()) {
    return {};
  }
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return {};
  }

  LARGE_INTEGER size{};
  if (!::GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
      size.QuadPart > 4 * 1024 * 1024) {
    ::CloseHandle(file);
    return {};
  }

  std::string content(static_cast<size_t>(size.QuadPart), '\0');
  DWORD bytes_read = 0;
  BOOL ok = ::ReadFile(file, content.data(), static_cast<DWORD>(content.size()),
                       &bytes_read, nullptr);
  ::CloseHandle(file);
  if (!ok) {
    return {};
  }
  content.resize(static_cast<size_t>(bytes_read));
  return LoadDeviceCacheFromJson(content);
}

std::wstring QuoteWindowsArg(const std::wstring& arg) {
  if (!arg.empty() &&
      arg.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    return arg;
  }

  std::wstring out = L"\"";
  for (size_t i = 0; i < arg.size(); ++i) {
    size_t backslashes = 0;
    while (i < arg.size() && arg[i] == L'\\') {
      ++backslashes;
      ++i;
    }
    if (i == arg.size()) {
      out.append(backslashes * 2, L'\\');
      break;
    }
    if (arg[i] == L'"') {
      out.append(backslashes * 2 + 1, L'\\');
      out.push_back(L'"');
    } else {
      out.append(backslashes, L'\\');
      out.push_back(arg[i]);
    }
  }
  out.push_back(L'"');
  return out;
}

std::wstring BuildSendCommandLine(const std::wstring& exe_path,
                                  const std::wstring& fingerprint,
                                  const std::vector<std::wstring>& paths) {
  std::wstring cmd = QuoteWindowsArg(exe_path);
  if (fingerprint.empty()) {
    return cmd;
  }
  cmd += L" --hidden --send-to ";
  cmd += QuoteWindowsArg(fingerprint);
  for (const auto& path : paths) {
    cmd += L" ";
    cmd += QuoteWindowsArg(path);
  }
  return cmd;
}
