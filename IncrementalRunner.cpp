#define _CRT_SECURE_NO_WARNINGS
#include <algorithm>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <shlwapi.h>
#include <sstream>
#include <string>
#include <unordered_map>
#include <windows.h>

#ifdef _DEBUG
#define DebugPrint(...) printf(__VA_ARGS__)
#else
#define DebugPrint(...)
#endif

static const wchar_t* kCompleteFlagName = L"complete.flag";
static const wchar_t* kReadFilesName = L"readfiles.txt";
static const wchar_t* kWriteFilesName = L"writefiles.txt";
static const wchar_t* kLockName = L"cache.lock";

//https://stackoverflow.com/questions/6218325/how-do-you-check-if-a-directory-exists-on-windows-in-c
BOOL DirectoryExists(LPCWSTR szPath)
{
	DWORD dwAttrib = GetFileAttributesW(szPath);
	return (dwAttrib != INVALID_FILE_ATTRIBUTES && (dwAttrib & FILE_ATTRIBUTE_DIRECTORY));
}

static_assert(sizeof(FILETIME) == sizeof(uint64_t));

uint64_t FileTimeToUInt64(FILETIME ft)
{
	ULARGE_INTEGER uli;
	uli.LowPart = ft.dwLowDateTime;
	uli.HighPart = ft.dwHighDateTime;
	return uli.QuadPart;
}

std::string WideToUtf8(const std::wstring& wide)
{
	if (wide.empty())
	{
		return {};
	}
	int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), nullptr, 0, nullptr, nullptr);
	if (size <= 0)
	{
		return {};
	}
	std::string utf8(size, '\0');
	WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), &utf8[0], size, nullptr, nullptr);
	return utf8;
}

std::wstring Utf8ToWide(const std::string& utf8)
{
	if (utf8.empty())
	{
		return {};
	}
	int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), nullptr, 0);
	if (size <= 0)
	{
		return {};
	}
	std::wstring wide(size, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), &wide[0], size);
	return wide;
}

static bool IsAbsoluteWinPath(const std::wstring& path)
{
	if (path.size() >= 2 && path[0] == L'\\' && path[1] == L'\\')
	{
		return true;
	}
	return path.size() >= 3 && path[1] == L':' && (path[2] == L'\\' || path[2] == L'/');
}

// Win32 CreateFileW rejects paths >= MAX_PATH unless given the \\?\ / \\?\UNC\ form.
// That prefix is invalid on relative paths ("\\?\input.txt" does not open), so only
// absolute paths are rewritten. '/' is normalized because \\?\ paths are not.
std::wstring ToExtendedPath(const std::wstring& path)
{
	if (path.empty() || path.rfind(L"\\\\?\\", 0) == 0)
	{
		return path;
	}
	if (!IsAbsoluteWinPath(path))
	{
		return path;
	}

	const std::wstring prefix = (path[0] == L'\\' && path[1] == L'\\') ? L"\\\\?\\UNC\\" : L"\\\\?\\";
	const size_t rest_begin = (path[0] == L'\\' && path[1] == L'\\') ? 2 : 0;
	std::wstring extended;
	extended.reserve(prefix.size() + path.size() - rest_begin);
	extended.append(prefix);
	for (size_t i = rest_begin; i < path.size(); i++)
	{
		const wchar_t ch = path[i];
		extended.push_back(ch == L'/' ? L'\\' : ch);
	}
	return extended;
}

// Returns false if the path cannot be opened (missing, ACL, sharing). Callers must
// treat failure as dirty — never equate "unreadable" with FILETIME zero.
bool GetFileModifiedTime(LPCWSTR lpFileName, FILETIME* out_ft)
{
	const std::wstring extended = ToExtendedPath(lpFileName);
	HANDLE hFile = CreateFileW(extended.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
	if (hFile == INVALID_HANDLE_VALUE)
	{
		return false;
	}
	FILETIME CreationTime{};
	FILETIME LastAccessTime{};
	FILETIME LastWriteTime{};
	const BOOL ok = GetFileTime(hFile, &CreationTime, &LastAccessTime, &LastWriteTime);
	CloseHandle(hFile);
	if (!ok)
	{
		return false;
	}
	*out_ft = LastWriteTime;
	return true;
}

// FNV-1a 64-bit. Public-domain, fixed constants, so cache directory names do not
// change across MSVC/STL updates the way std::hash<std::string> can.
// Offset basis 14695981039346656037, prime 1099511628211.
// http://www.isthe.com/chongo/tech/comp/fnv/
uint64_t Fnv1a64(const unsigned char* data, size_t len)
{
	uint64_t hash = 14695981039346656037ull;
	for (size_t i = 0; i < len; i++)
	{
		hash ^= data[i];
		hash *= 1099511628211ull;
	}
	return hash;
}

// Identity bytes: UTF-8 command, one 0x00 separator, UTF-8 normalized cwd.
// The separator keeps command "ab" + cwd "c" distinct from command "a" + cwd "bc".
bool HashCacheKey(const std::wstring& command_line, const std::wstring& cwd, uint64_t* out_hash)
{
	const std::string cmd_utf8 = WideToUtf8(command_line);
	const std::string cwd_utf8 = WideToUtf8(cwd);
	if ((!command_line.empty() && cmd_utf8.empty()) || cwd.empty() || cwd_utf8.empty())
	{
		return false;
	}
	std::string bytes;
	bytes.reserve(cmd_utf8.size() + 1 + cwd_utf8.size());
	bytes.append(cmd_utf8);
	bytes.push_back('\0');
	bytes.append(cwd_utf8);
	*out_hash = Fnv1a64(reinterpret_cast<const unsigned char*>(bytes.data()), bytes.size());
	return true;
}

// On success these APIs return the length without the null, and that length is
// smaller than the buffer. When the buffer is too small they return the required
// size including the null.
std::wstring QueryFullPath(const std::wstring& raw)
{
	wchar_t stack_buf[MAX_PATH];
	const DWORD n = GetFullPathNameW(raw.c_str(), MAX_PATH, stack_buf, nullptr);
	if (n == 0)
	{
		return {};
	}
	if (n < MAX_PATH)
	{
		return std::wstring(stack_buf, n);
	}
	std::wstring heap(n, L'\0');
	const DWORD n2 = GetFullPathNameW(raw.c_str(), n, &heap[0], nullptr);
	if (n2 == 0 || n2 >= n)
	{
		return {};
	}
	heap.resize(n2);
	return heap;
}

std::wstring QueryCurrentDirectory()
{
	wchar_t stack_buf[MAX_PATH];
	const DWORD n = GetCurrentDirectoryW(MAX_PATH, stack_buf);
	if (n == 0)
	{
		return {};
	}
	if (n < MAX_PATH)
	{
		return std::wstring(stack_buf, n);
	}
	std::wstring heap(n, L'\0');
	const DWORD n2 = GetCurrentDirectoryW(n, &heap[0]);
	if (n2 == 0 || n2 >= n)
	{
		return {};
	}
	heap.resize(n2);
	return heap;
}

// Absolute cwd, backslashes, no trailing slash except a drive root ("C:\").
// "\\?\UNC\..." becomes "\\..." and "\\?\C:\..." becomes "C:\..." so the extended
// form hashes the same as the Win32 form. Not case-folded.
std::wstring NormalizeWorkingDirectory(const std::wstring& raw)
{
	if (raw.empty())
	{
		return {};
	}
	std::wstring full = QueryFullPath(raw);
	if (full.empty())
	{
		return {};
	}

	for (wchar_t& ch : full)
	{
		if (ch == L'/')
		{
			ch = L'\\';
		}
	}

	const std::wstring unc_prefix = L"\\\\?\\UNC\\";
	const std::wstring ext_prefix = L"\\\\?\\";
	if (full.rfind(unc_prefix, 0) == 0)
	{
		full.replace(0, unc_prefix.size(), L"\\\\");
	}
	else if (full.rfind(ext_prefix, 0) == 0)
	{
		full.erase(0, ext_prefix.size());
	}

	while (full.size() > 3 && full.back() == L'\\')
	{
		full.pop_back();
	}

	const bool drive = full.size() >= 3 && full[1] == L':' && full[2] == L'\\';
	const bool unc = full.size() >= 2 && full[0] == L'\\' && full[1] == L'\\';
	if (!drive && !unc)
	{
		return {};
	}
	return full;
}

std::wstring GetNormalizedWorkingDirectory()
{
	const std::wstring raw = QueryCurrentDirectory();
	if (raw.empty())
	{
		return {};
	}
	return NormalizeWorkingDirectory(raw);
}

// Returns -1 and prints a reason when path contains '"'. Otherwise 0.
// Tracker and cache paths are wrapped in quotes on the Tracker command line and
// are not escaped, so an embedded quote would split the child command.
int FailIfPathContainsQuote(const char* label, const std::wstring& path)
{
	if (path.find(L'"') == std::wstring::npos)
	{
		return 0;
	}
	const std::string shown = WideToUtf8(path);
	fprintf(stderr,
		"SimpleInc: %s must not contain a double-quote (\").\n"
		"That path is embedded unescaped in the Tracker command line.\n"
		"Path: %s\n",
		label,
		shown.c_str());
	return -1;
}

std::wstring GetTempDir(const std::wstring& temp_dir, uint64_t hash)
{
	return temp_dir + L"\\" + std::to_wstring(hash);
}

std::wstring JoinPath(const std::wstring& dir, const wchar_t* name)
{
	return dir + L"\\" + name;
}

bool CacheComplete(const std::wstring& cache_dir)
{
	return PathFileExistsW(JoinPath(cache_dir, kCompleteFlagName).c_str()) != FALSE;
}

// Returns true if the command must be re-run (cache missing, incomplete, or stale).
bool CheckIfOutOfDate(const std::wstring& cache_dir)
{
	if (!DirectoryExists(cache_dir.c_str()))
	{
		CreateDirectoryW(cache_dir.c_str(), NULL);
		return true;
	}

	// Without a completion sentinel, an empty/partial cache after ClearCacheDir
	// must never be treated as up-to-date.
	if (!CacheComplete(cache_dir))
	{
		DebugPrint("Cache incomplete (missing complete.flag)\n");
		return true;
	}

	auto check_mtime_list = [](const std::wstring& list_path, const char* label) -> bool
	{
		std::ifstream files(std::filesystem::path(list_path), std::ios::binary);
		if (!files.good())
		{
			DebugPrint("Could not open %s\n", label);
			return true; // missing/unreadable → dirty
		}

		std::string path, filetime;
		while (std::getline(files, path))
		{
			if (!std::getline(files, filetime))
			{
				DebugPrint("Truncated cache entry in %s\n", label);
				return true;
			}
			if (path.empty())
			{
				continue;
			}

			uint64_t filetime_before_u64 = 0;
			try
			{
				filetime_before_u64 = std::stoull(filetime);
			}
			catch (...)
			{
				DebugPrint("Invalid mtime in %s for %s\n", label, path.c_str());
				return true;
			}

			const std::wstring wide_path = Utf8ToWide(path);
			FILETIME filetime_now{};
			if (!GetFileModifiedTime(wide_path.c_str(), &filetime_now))
			{
				DebugPrint("Missing/unreadable since last run (%s): %s\n", label, path.c_str());
				return true;
			}
			const uint64_t filetime_now_u64 = FileTimeToUInt64(filetime_now);
			if (filetime_now_u64 != filetime_before_u64)
			{
				DebugPrint("File modified since last run (%s): %s\n", label, path.c_str());
				return true;
			}
		}
		return false;
	};

	if (check_mtime_list(JoinPath(cache_dir, kReadFilesName), "readfiles.txt"))
	{
		return true;
	}
	if (check_mtime_list(JoinPath(cache_dir, kWriteFilesName), "writefiles.txt"))
	{
		return true;
	}
	return false;
}

// tracker_path and cache_folder are wrapped in quotes and are not escaped.
// wmain rejects '"' in those paths before this runs.
std::wstring BuildTrackerCommandLine(const std::wstring& tracker_path, const std::wstring& cache_folder, const std::wstring& command_line)
{
	std::wstringstream s;
	s << L"\"" << tracker_path << L"\"" << L" /i \"" << cache_folder << L"\" /c ";
	s << command_line;
	return s.str();
}

DWORD RunCommand(std::wstring& cmd)
{
	DebugPrint("Running command: %s\n", WideToUtf8(cmd).c_str());
	STARTUPINFOW si;
	PROCESS_INFORMATION pi;

	ZeroMemory(&si, sizeof(si));
	si.cb = sizeof(si);
	ZeroMemory(&pi, sizeof(pi));

	// Start the child process (Unicode command line so non-ASCII paths survive).
	if (!CreateProcessW(NULL,   // No module name (use command line)
		cmd.data(), // Command line (mutable buffer required by CreateProcessW)
		NULL,       // Process handle not inheritable
		NULL,       // Thread handle not inheritable
		FALSE,      // Set handle inheritance to FALSE
		0,          // No creation flags
		NULL,       // Use parent's environment block
		NULL,       // Use parent's starting directory
		&si,        // Pointer to STARTUPINFOW structure
		&pi)        // Pointer to PROCESS_INFORMATION structure
		)
	{
		DebugPrint("CreateProcess failed (%d).\n", GetLastError());
		return -1;
	}

	// Wait until child process exits.
	WaitForSingleObject(pi.hProcess, INFINITE);

	DWORD exit_code = -1;
	GetExitCodeProcess(pi.hProcess, &exit_code);

	DebugPrint("Process returend exit code: %i\n", exit_code);

	// Close process and thread handles.
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);

	return exit_code;
}

// Tracker.exe writes UTF-16 text with an optional BOM. Accept CRLF and LF;
// include a final line that lacks a trailing newline. Returns false on I/O failure
// (caller must not publish a complete cache after a failed tlog read).
template <typename LAMBDA_PER_LINE>
bool ProcessUTF16FileByLine(const std::wstring& file_path, LAMBDA_PER_LINE lambda)
{
	static_assert(sizeof(wchar_t) == 2);
	FILE* f = _wfopen(file_path.c_str(), L"rb");
	if (!f)
	{
		DebugPrint("Failed to open file for reading: %s\n", WideToUtf8(file_path).c_str());
		return false;
	}
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (len < 0)
	{
		fclose(f);
		return false;
	}
	if (len == 0)
	{
		fclose(f);
		return true;
	}
	if ((len % (long)sizeof(wchar_t)) != 0)
	{
		DebugPrint("UTF-16 file has odd byte length, truncating: %s\n", WideToUtf8(file_path).c_str());
		len -= (len % (long)sizeof(wchar_t));
	}
	// +1 wchar_t so a final line without a newline can be null-terminated in place.
	wchar_t* data = (wchar_t*)malloc((size_t)len + sizeof(wchar_t));
	if (!data)
	{
		DebugPrint("malloc failed to allocate %i bytes\n", len);
		fclose(f);
		return false;
	}
	const size_t bytes_read = fread(data, 1, (size_t)len, f);
	fclose(f);
	if (bytes_read != (size_t)len)
	{
		DebugPrint("Short read on %s (%zu of %ld bytes)\n", WideToUtf8(file_path).c_str(), bytes_read, len);
		free(data);
		return false;
	}

	long characters = len / (long)sizeof(wchar_t);
	data[characters] = L'\0';
	long start = 0;
	for (long i = 0; i < characters; i++)
	{
		if (i == start && data[i] == (wchar_t)0xFEFF) // BOM at start of content
		{
			start = i + 1;
			continue;
		}

		if (data[i] == L'\n' || data[i] == L'\r')
		{
			const bool crlf = (data[i] == L'\r' && (i + 1) < characters && data[i + 1] == L'\n');
			data[i] = L'\0';
			if (start < i)
			{
				lambda(&(data[start]));
			}
			if (crlf)
			{
				start = i + 2;
				i++; // skip LF; for-loop will advance past it
			}
			else
			{
				start = i + 1;
			}
		}
	}
	if (start < characters)
	{
		lambda(&(data[start]));
	}
	free(data);
	return true;
}

void ClearReadonlyAttribute(const std::wstring& path)
{
	const DWORD attrs = GetFileAttributesW(path.c_str());
	if (attrs == INVALID_FILE_ATTRIBUTES)
	{
		return;
	}
	if (attrs & FILE_ATTRIBUTE_READONLY)
	{
		SetFileAttributesW(path.c_str(), attrs & ~FILE_ATTRIBUTE_READONLY);
	}
}

void ClearCacheDir(const std::wstring& cache_dir)
{
	DebugPrint("Clearing cache directory %s\n", WideToUtf8(cache_dir).c_str());
	std::error_code ec;
	const std::filesystem::path root(cache_dir);
	if (!std::filesystem::exists(root, ec))
	{
		return;
	}
	for (const auto& entry : std::filesystem::directory_iterator(root, ec))
	{
		// cache.lock is held open for the duration of clear -> run -> publish.
		if (entry.path().filename().wstring() == kLockName)
		{
			continue;
		}
		const std::wstring entry_path = entry.path().wstring();
		// A read-only cache file otherwise survives remove_all / MoveFileEx and
		// every later dirty rebuild exits -1 without publishing.
		ClearReadonlyAttribute(entry_path);
		std::filesystem::remove_all(entry.path(), ec);
	}
}

bool WriteUtf8FileAtomic(const std::wstring& final_path, const std::string& contents)
{
	std::wstring temp_path = final_path;
	temp_path += L".tmp";

	{
		std::ofstream out(std::filesystem::path(temp_path), std::ios::binary | std::ios::trunc);
		if (!out.good())
		{
			DebugPrint("Failed to open temp cache file: %s\n", WideToUtf8(temp_path).c_str());
			return false;
		}
		out.write(contents.data(), (std::streamsize)contents.size());
		if (!out.good())
		{
			DebugPrint("Failed to write temp cache file: %s\n", WideToUtf8(temp_path).c_str());
			return false;
		}
	}

	ClearReadonlyAttribute(final_path);
	if (!MoveFileExW(temp_path.c_str(), final_path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
	{
		DebugPrint("Failed to publish cache file %s (%lu)\n", WideToUtf8(final_path).c_str(), GetLastError());
		DeleteFileW(temp_path.c_str());
		return false;
	}
	return true;
}

bool IsWriteTlogFilename(const std::filesystem::path& path)
{
	// Tracker names files like tool.write.1.tlog / tool.read.1.tlog — classify by filename only.
	const std::wstring filename = path.filename().wstring();
	return filename.find(L".write.") != std::wstring::npos;
}

bool BuildCacheFile(const std::wstring& cache_dir)
{
	std::unordered_map<std::wstring, FILETIME> read_files;
	std::unordered_map<std::wstring, FILETIME> write_files;
	std::error_code ec;
	for (const auto& entry : std::filesystem::directory_iterator(std::filesystem::path(cache_dir), ec))
	{
		if (entry.path().extension() != L".tlog")
		{
			continue;
		}

		DebugPrint("Processing file: %ls\n", entry.path().c_str());
		std::unordered_map<std::wstring, FILETIME>* map_files =
			IsWriteTlogFilename(entry.path()) ? &write_files : &read_files;

		if (!ProcessUTF16FileByLine(entry.path().wstring(), [&](wchar_t* line)
			{
				if (line[0] == L'\0')
				{
					return;
				}
				if (line[0] == L'#')
				{
					return; // Tracker header / comment lines
				}

				std::wstring wstr(line);
				auto it = map_files->find(wstr);
				if (it == map_files->end())
				{
					FILETIME ft{};
					// Missing at stamp time → zero FILETIME; CheckIfOutOfDate treats
					// later open failures as dirty so the entry cannot go permanently stale.
					if (!GetFileModifiedTime(line, &ft))
					{
						ft = {};
					}
					map_files->emplace(std::move(wstr), ft);
					DebugPrint("\t%ls\n", line);
				}
			}))
		{
			DebugPrint("Aborting cache publish after tlog read failure.\n");
			return false;
		}

		DeleteFileW(entry.path().c_str());
	}

	// Zero reads and zero writes is indistinguishable from Tracker failing to
	// record real file access. Do not publish complete.flag. The caller clears
	// the directory (cache.lock stays) and exits non-zero so the next run retries.
	if (read_files.empty() && write_files.empty())
	{
		fprintf(stderr, "SimpleInc: Tracker recorded no read or write paths; not publishing a stamp.\n");
		return false;
	}

	auto serialize_map = [](const std::unordered_map<std::wstring, FILETIME>& files) -> std::string
	{
		std::string out;
		for (const auto& f : files)
		{
			out += WideToUtf8(f.first);
			out += '\n';
			out += std::to_string(FileTimeToUInt64(f.second));
			out += '\n';
		}
		return out;
	};

	const std::wstring read_path = JoinPath(cache_dir, kReadFilesName);
	const std::wstring write_path = JoinPath(cache_dir, kWriteFilesName);
	const std::wstring complete_path = JoinPath(cache_dir, kCompleteFlagName);

	// Ensure a prior incomplete publish cannot leave a stale sentinel.
	ClearReadonlyAttribute(complete_path);
	DeleteFileW(complete_path.c_str());

	if (!WriteUtf8FileAtomic(read_path, serialize_map(read_files)))
	{
		return false;
	}
	if (!WriteUtf8FileAtomic(write_path, serialize_map(write_files)))
	{
		return false;
	}

	// Sentinel last: only present when both cache files were published successfully.
	if (!WriteUtf8FileAtomic(complete_path, "ok\n"))
	{
		return false;
	}
	return true;
}

void PrintUsage()
{
	printf("Arg 0: Tracker.exe Directory (e.g. $(MSBuildBinPath) from Visual Studio)\n");
	printf("Arg 1: Cache Directory\n");
	printf("Arg 2: Command Line (Don't do anything special here, just pass it as if you were going to call it normally)\n");
}

#ifdef USE_TIMER
struct ScopedTimer
{
	using Clock = std::chrono::high_resolution_clock;
	~ScopedTimer()
	{
		float time_milliseconds = std::chrono::duration<float>(Clock::now() - start_time).count() * 1000.0f;
		printf("Time: %0.1fms\n", time_milliseconds);
	}
	const Clock::time_point start_time = Clock::now();
};
#endif

// Exclusive per-hash-dir lock. Held across the out-of-date check, clear, child, and
// publish so two identical commands cannot interleave tlog deletes and stamps.
// The file is intentionally left in the hash dir; the mutex is the open handle
// (share mode 0), which the OS drops if this process dies.
struct CacheDirLock
{
	HANDLE handle = INVALID_HANDLE_VALUE;

	bool TryAcquire(const std::wstring& cache_dir)
	{
		const std::wstring dir_to_create = ToExtendedPath(cache_dir);
		if (!CreateDirectoryW(dir_to_create.c_str(), NULL))
		{
			const DWORD err = GetLastError();
			if (err != ERROR_ALREADY_EXISTS)
			{
				DebugPrint("CreateDirectory for cache lock failed (%lu)\n", err);
				return false;
			}
		}

		const std::wstring lock_path = ToExtendedPath(JoinPath(cache_dir, kLockName));
		ClearReadonlyAttribute(lock_path);

		for (;;)
		{
			handle = CreateFileW(
				lock_path.c_str(),
				GENERIC_READ | GENERIC_WRITE,
				0, // exclusive
				NULL,
				OPEN_ALWAYS,
				FILE_ATTRIBUTE_NORMAL,
				NULL);
			if (handle != INVALID_HANDLE_VALUE)
			{
				return true;
			}
			const DWORD err = GetLastError();
			if (err != ERROR_SHARING_VIOLATION && err != ERROR_LOCK_VIOLATION)
			{
				DebugPrint("CreateFile cache.lock failed (%lu)\n", err);
				return false;
			}
			Sleep(25);
		}
	}

	~CacheDirLock()
	{
		if (handle != INVALID_HANDLE_VALUE)
		{
			CloseHandle(handle);
			handle = INVALID_HANDLE_VALUE;
		}
	}

	CacheDirLock() = default;
	CacheDirLock(const CacheDirLock&) = delete;
	CacheDirLock& operator=(const CacheDirLock&) = delete;
};

// Return the arg and its index in GetCommandLineW (wchar offsets).
std::pair<std::wstring, int> GetCommandToRun(size_t arg_idx)
{
	// We use GetCommandLineW here rather than params passed to wmain because argv has the quotes stripped.
	LPCWSTR pCommandLine = GetCommandLineW();

	size_t length = wcslen(pCommandLine);

	// Find where the arg_idx begins
	int arg_start = 0;
	int arg_cnt = 0;
	int quote_cnt = 0;
	for (int i = 0; i < (int)length; i++)
	{
		if (pCommandLine[i] == L'\"')
		{
			quote_cnt++;
		}
		else if (pCommandLine[i] == L' ' && (quote_cnt % 2) == 0)
		{
			//Skip ahead any additional spaces in the command line
			while (pCommandLine[i] == L' ')
			{
				i++;
			}
			i--;

			if (arg_cnt == (int)arg_idx)
			{
				return { std::wstring(&(pCommandLine[arg_start]), i - arg_start), arg_start };
			}
			arg_start = i + 1;
			arg_cnt++;
		}
	}
	return { std::wstring(&(pCommandLine[arg_start]), length - arg_start), arg_start };
}

int wmain(int argc, wchar_t* argv[])
{
#ifdef USE_TIMER
	ScopedTimer timer;
#endif
	// argv[0]=exe, argv[1]=Tracker dir, argv[2]=cache dir, argv[3...]=command
	if (argc < 4)
	{
		PrintUsage();
		return -1;
	}

	const int tracker_quote_err = FailIfPathContainsQuote("Tracker directory", argv[1]);
	if (tracker_quote_err != 0)
	{
		return tracker_quote_err;
	}
	const int cache_quote_err = FailIfPathContainsQuote("Cache directory", argv[2]);
	if (cache_quote_err != 0)
	{
		return cache_quote_err;
	}

	std::wstring tracker_path(argv[1]);
	tracker_path += L"\\Tracker.exe";

	// We use GetCommandLineW here rather than params passed to wmain because argv has the quotes stripped.
	// The remainder is the absolute command text: hashed and launched exactly as written.
	std::wstring command_line = GetCommandLineW() + GetCommandToRun(3).second;

	const std::wstring cwd = GetNormalizedWorkingDirectory();
	if (cwd.empty())
	{
		fprintf(stderr, "SimpleInc: failed to read an absolute working directory (%lu).\n", GetLastError());
		return -1;
	}

	// FNV-1a over the UTF-8 command bytes plus the normalized cwd. Directory names
	// differ from the old std::hash of the command alone; that cold cache is intended.
	uint64_t command_line_hash = 0;
	if (!HashCacheKey(command_line, cwd, &command_line_hash))
	{
		fprintf(stderr, "SimpleInc: failed to encode the command or working directory as UTF-8.\n");
		return -1;
	}

	const std::wstring cache_dir = GetTempDir(argv[2], command_line_hash);

	// Re-check inside the lock. A waiter that observed "dirty" before the winner
	// published must skip instead of clearing that fresh stamp and running again.
	CacheDirLock cache_lock;
	if (!cache_lock.TryAcquire(cache_dir))
	{
		DebugPrint("Failed to acquire cache lock.\n");
		return -1;
	}

	if (CheckIfOutOfDate(cache_dir))
	{
		ClearCacheDir(cache_dir); // Clear any cache files from previous run
		std::wstring cmd = BuildTrackerCommandLine(tracker_path, cache_dir, command_line);
		const DWORD ret = RunCommand(cmd);
		if (ret == 0)
		{
			// Process succeeded, process and write cache files.
			if (!BuildCacheFile(cache_dir))
			{
				ClearCacheDir(cache_dir);
				DebugPrint("Failed to publish cache; cleared incomplete cache dir.\n");
				return -1;
			}
		}
		else
		{
			// Process returned error exit code. Clear cache dir.
			ClearCacheDir(cache_dir);
		}
		return ret;
	}
	// We are up to date!
	DebugPrint("Command is up to date. Exiting.\n");
	return 0;
}
