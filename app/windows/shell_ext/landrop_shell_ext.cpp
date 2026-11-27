#include <windows.h>
#include <objbase.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <shobjidl_core.h>

#include <atomic>
#include <new>
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

HMODULE g_hModule = nullptr;
std::atomic<long> g_dllRefCount{0};

std::wstring GetModuleDirectory() {
  wchar_t buffer[MAX_PATH] = {};
  DWORD len = ::GetModuleFileNameW(g_hModule, buffer, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return L"";
  }
  std::wstring path(buffer, len);
  size_t slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return L"";
  }
  return path.substr(0, slash);
}

bool FileExists(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  DWORD attrs = ::GetFileAttributesW(path.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES &&
         (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::wstring ResolveLanDropExePath(const DeviceCacheData& cache) {
  if (FileExists(cache.exe_path)) {
    return cache.exe_path;
  }
  std::wstring dir = GetModuleDirectory();
  if (!dir.empty()) {
    std::wstring sibling = dir + L"\\landrop.exe";
    if (FileExists(sibling)) {
      return sibling;
    }
  }
  return cache.exe_path.empty() ? L"landrop.exe" : cache.exe_path;
}

std::wstring ResolveIconPath(const std::wstring& exe_path) {
  if (FileExists(exe_path)) {
    return exe_path + L",0";
  }
  std::wstring dir = GetModuleDirectory();
  if (!dir.empty()) {
    std::wstring sibling = dir + L"\\landrop.exe";
    if (FileExists(sibling)) {
      return sibling + L",0";
    }
  }
  return L"";
}

std::vector<std::wstring> CollectSelectedPaths(IShellItemArray* items) {
  std::vector<std::wstring> paths;
  if (items == nullptr) {
    return paths;
  }
  DWORD count = 0;
  if (FAILED(items->GetCount(&count))) {
    return paths;
  }
  for (DWORD i = 0; i < count; ++i) {
    IShellItem* item = nullptr;
    if (SUCCEEDED(items->GetItemAt(i, &item)) && item != nullptr) {
      PWSTR fs_path = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &fs_path)) &&
          fs_path != nullptr) {
        paths.emplace_back(fs_path);
        ::CoTaskMemFree(fs_path);
      }
      item->Release();
    }
  }
  return paths;
}

class LanDropDeviceCommand final : public IExplorerCommand {
 public:
  LanDropDeviceCommand(std::wstring title,
                       std::wstring fingerprint,
                       std::wstring exe_path)
      : title_(std::move(title)),
        fingerprint_(std::move(fingerprint)),
        exe_path_(std::move(exe_path)) {
    g_dllRefCount.fetch_add(1, std::memory_order_relaxed);
  }

  ~LanDropDeviceCommand() {
    g_dllRefCount.fetch_sub(1, std::memory_order_relaxed);
  }

  IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (ppv == nullptr) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IExplorerCommand) {
      *ppv = static_cast<IExplorerCommand*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  IFACEMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1, std::memory_order_relaxed) + 1);
  }

  IFACEMETHODIMP_(ULONG) Release() override {
    long count = ref_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
    if (count == 0) {
      delete this;
    }
    return static_cast<ULONG>(count);
  }

  IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* ppszName) override {
    return ::SHStrDupW(title_.c_str(), ppszName);
  }

  IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* ppszIcon) override {
    std::wstring icon = ResolveIconPath(exe_path_);
    if (icon.empty()) {
      *ppszIcon = nullptr;
      return E_NOTIMPL;
    }
    return ::SHStrDupW(icon.c_str(), ppszIcon);
  }

  IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* ppszInfotip) override {
    *ppszInfotip = nullptr;
    return E_NOTIMPL;
  }

  IFACEMETHODIMP GetCanonicalName(GUID* pguidCommandName) override {
    *pguidCommandName = GUID_NULL;
    return E_NOTIMPL;
  }

  IFACEMETHODIMP GetState(IShellItemArray*, BOOL, EXPCMDSTATE* pCmdState) override {
    *pCmdState = ECS_ENABLED;
    return S_OK;
  }

  IFACEMETHODIMP Invoke(IShellItemArray* psiItemArray, IBindCtx*) override {
    std::vector<std::wstring> paths = CollectSelectedPaths(psiItemArray);
    std::wstring cmd = BuildSendCommandLine(exe_path_, fingerprint_, paths);
    std::vector<wchar_t> mutable_cmd(cmd.begin(), cmd.end());
    mutable_cmd.push_back(L'\0');

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    DWORD flags = fingerprint_.empty() ? 0 : (CREATE_NO_WINDOW | DETACHED_PROCESS);
    BOOL launched = ::CreateProcessW(
        exe_path_.c_str(), mutable_cmd.data(), nullptr, nullptr, FALSE, flags,
        nullptr, nullptr, &si, &pi);
    if (!launched) {
      return HRESULT_FROM_WIN32(::GetLastError());
    }
    ::CloseHandle(pi.hThread);
    ::CloseHandle(pi.hProcess);
    return S_OK;
  }

  IFACEMETHODIMP GetFlags(EXPCMDFLAGS* pFlags) override {
    *pFlags = ECF_DEFAULT;
    return S_OK;
  }

  IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** ppEnum) override {
    *ppEnum = nullptr;
    return E_NOTIMPL;
  }

 private:
  std::atomic<long> ref_count_{1};
  std::wstring title_;
  std::wstring fingerprint_;
  std::wstring exe_path_;
};

class LanDropEnumCommands final : public IEnumExplorerCommand {
 public:
  explicit LanDropEnumCommands(std::vector<IExplorerCommand*> commands,
                               size_t index = 0)
      : commands_(std::move(commands)), index_(index) {
    g_dllRefCount.fetch_add(1, std::memory_order_relaxed);
  }

  ~LanDropEnumCommands() {
    for (auto* cmd : commands_) {
      if (cmd != nullptr) {
        cmd->Release();
      }
    }
    g_dllRefCount.fetch_sub(1, std::memory_order_relaxed);
  }

  IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (ppv == nullptr) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IEnumExplorerCommand) {
      *ppv = static_cast<IEnumExplorerCommand*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  IFACEMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1, std::memory_order_relaxed) + 1);
  }

  IFACEMETHODIMP_(ULONG) Release() override {
    long count = ref_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
    if (count == 0) {
      delete this;
    }
    return static_cast<ULONG>(count);
  }

  IFACEMETHODIMP Next(ULONG celt,
                      IExplorerCommand** pUICommand,
                      ULONG* pceltFetched) override {
    if (pUICommand == nullptr) return E_POINTER;
    ULONG fetched = 0;
    while (fetched < celt && index_ < commands_.size()) {
      pUICommand[fetched] = commands_[index_];
      pUICommand[fetched]->AddRef();
      ++fetched;
      ++index_;
    }
    if (pceltFetched != nullptr) {
      *pceltFetched = fetched;
    }
    return (fetched == celt) ? S_OK : S_FALSE;
  }

  IFACEMETHODIMP Skip(ULONG celt) override {
    size_t remaining = commands_.size() - index_;
    if (static_cast<size_t>(celt) > remaining) {
      index_ = commands_.size();
      return S_FALSE;
    }
    index_ += static_cast<size_t>(celt);
    return S_OK;
  }

  IFACEMETHODIMP Reset() override {
    index_ = 0;
    return S_OK;
  }

  IFACEMETHODIMP Clone(IEnumExplorerCommand** ppenum) override {
    if (ppenum == nullptr) return E_POINTER;
    std::vector<IExplorerCommand*> cloned;
    cloned.reserve(commands_.size());
    for (auto* cmd : commands_) {
      if (cmd != nullptr) {
        cmd->AddRef();
        cloned.push_back(cmd);
      }
    }
    auto* copy = new (std::nothrow) LanDropEnumCommands(std::move(cloned), index_);
    if (copy == nullptr) {
      for (auto* cmd : cloned) {
        cmd->Release();
      }
      *ppenum = nullptr;
      return E_OUTOFMEMORY;
    }
    *ppenum = copy;
    return S_OK;
  }

 private:
  std::atomic<long> ref_count_{1};
  std::vector<IExplorerCommand*> commands_;
  size_t index_ = 0;
};

class LanDropRootCommand final : public IExplorerCommand {
 public:
  LanDropRootCommand() {
    g_dllRefCount.fetch_add(1, std::memory_order_relaxed);
  }

  ~LanDropRootCommand() {
    g_dllRefCount.fetch_sub(1, std::memory_order_relaxed);
  }

  IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (ppv == nullptr) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IExplorerCommand) {
      *ppv = static_cast<IExplorerCommand*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  IFACEMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1, std::memory_order_relaxed) + 1);
  }

  IFACEMETHODIMP_(ULONG) Release() override {
    long count = ref_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
    if (count == 0) {
      delete this;
    }
    return static_cast<ULONG>(count);
  }

  IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* ppszName) override {
    return ::SHStrDupW(L"LanDrop", ppszName);
  }

  IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* ppszIcon) override {
    DeviceCacheData cache = LoadDeviceCacheFromFile(GetDefaultDeviceCachePath());
    std::wstring icon = ResolveIconPath(ResolveLanDropExePath(cache));
    if (icon.empty()) {
      *ppszIcon = nullptr;
      return E_NOTIMPL;
    }
    return ::SHStrDupW(icon.c_str(), ppszIcon);
  }

  IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* ppszInfotip) override {
    *ppszInfotip = nullptr;
    return E_NOTIMPL;
  }

  IFACEMETHODIMP GetCanonicalName(GUID* pguidCommandName) override {
    *pguidCommandName = CLSID_LanDropExplorerCommand;
    return S_OK;
  }

  IFACEMETHODIMP GetState(IShellItemArray* psiItemArray,
                          BOOL,
                          EXPCMDSTATE* pCmdState) override {
    *pCmdState = (psiItemArray != nullptr) ? ECS_ENABLED : ECS_HIDDEN;
    return S_OK;
  }

  IFACEMETHODIMP Invoke(IShellItemArray*, IBindCtx*) override {
    return E_NOTIMPL;
  }

  IFACEMETHODIMP GetFlags(EXPCMDFLAGS* pFlags) override {
    *pFlags = ECF_HASSUBCOMMANDS;
    return S_OK;
  }

  IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** ppEnum) override {
    if (ppEnum == nullptr) return E_POINTER;
    DeviceCacheData cache = LoadDeviceCacheFromFile(GetDefaultDeviceCachePath());
    std::wstring exe_path = ResolveLanDropExePath(cache);

    std::vector<IExplorerCommand*> items;
    for (const auto& dev : cache.devices) {
      std::wstring label = dev.alias;
      auto* cmd = new (std::nothrow)
          LanDropDeviceCommand(std::move(label), dev.fingerprint, exe_path);
      if (cmd != nullptr) {
        items.push_back(cmd);
      }
    }

    if (items.empty()) {
      auto* fallback = new (std::nothrow)
          LanDropDeviceCommand(L"Open LanDrop...", L"", exe_path);
      if (fallback != nullptr) {
        items.push_back(fallback);
      }
    }

    auto* enumerator = new (std::nothrow) LanDropEnumCommands(std::move(items));
    if (enumerator == nullptr) {
      for (auto* cmd : items) {
        cmd->Release();
      }
      *ppEnum = nullptr;
      return E_OUTOFMEMORY;
    }
    *ppEnum = enumerator;
    return S_OK;
  }

 private:
  std::atomic<long> ref_count_{1};
};

class LanDropClassFactory final : public IClassFactory {
 public:
  LanDropClassFactory() {
    g_dllRefCount.fetch_add(1, std::memory_order_relaxed);
  }

  ~LanDropClassFactory() {
    g_dllRefCount.fetch_sub(1, std::memory_order_relaxed);
  }

  IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (ppv == nullptr) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IClassFactory) {
      *ppv = static_cast<IClassFactory*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  IFACEMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1, std::memory_order_relaxed) + 1);
  }

  IFACEMETHODIMP_(ULONG) Release() override {
    long count = ref_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
    if (count == 0) {
      delete this;
    }
    return static_cast<ULONG>(count);
  }

  IFACEMETHODIMP CreateInstance(IUnknown* pUnkOuter,
                                REFIID riid,
                                void** ppvObject) override {
    if (ppvObject == nullptr) return E_POINTER;
    *ppvObject = nullptr;
    if (pUnkOuter != nullptr) return CLASS_E_NOAGGREGATION;

    auto* cmd = new (std::nothrow) LanDropRootCommand();
    if (cmd == nullptr) return E_OUTOFMEMORY;
    HRESULT hr = cmd->QueryInterface(riid, ppvObject);
    cmd->Release();
    return hr;
  }

  IFACEMETHODIMP LockServer(BOOL fLock) override {
    if (fLock) {
      g_dllRefCount.fetch_add(1, std::memory_order_relaxed);
    } else {
      g_dllRefCount.fetch_sub(1, std::memory_order_relaxed);
    }
    return S_OK;
  }

 private:
  std::atomic<long> ref_count_{1};
};

}  // namespace

BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID) {
  if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
    g_hModule = hModule;
    ::DisableThreadLibraryCalls(hModule);
  }
  return TRUE;
}

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID* ppv) {
  if (ppv == nullptr) return E_POINTER;
  *ppv = nullptr;
  if (rclsid != CLSID_LanDropExplorerCommand) {
    return CLASS_E_CLASSNOTAVAILABLE;
  }
  auto* factory = new (std::nothrow) LanDropClassFactory();
  if (factory == nullptr) return E_OUTOFMEMORY;
  HRESULT hr = factory->QueryInterface(riid, ppv);
  factory->Release();
  return hr;
}

STDAPI DllCanUnloadNow() {
  return (g_dllRefCount.load(std::memory_order_acquire) == 0) ? S_OK : S_FALSE;
}
