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

static const char* kCompleteFlagName = "complete.flag";
static const char* kReadFilesName = "readfiles.txt";
static const char* kWriteFilesName = "writefiles.txt";

//https://stackoverflow.com/questions/6218325/how-do-you-check-if-a-directory-exists-on-windows-in-c
BOOL DirectoryExists(LPCSTR szPath)
{
	DWORD dwAttrib = GetFileAttributesA(szPath);
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

FILETIME GetFileModifiedTime(LPCWSTR lpFileName)
{
	HANDLE hFile;
	FILETIME CreationTime;
	FILETIME LastAccessTime;
	FILETIME LastWriteTime;

	hFile = CreateFileW(lpFileName, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
	if (hFile != INVALID_HANDLE_VALUE)
	{
		if (GetFileTime(hFile, &CreationTime, &LastAccessTime, &LastWriteTime))
		{
			CloseHandle(hFile);
			return LastWriteTime;
		}
		CloseHandle(hFile);
	}
	return {};
}

std::string GetTempDir(const char* temp_dir, size_t hash)
{
	std::string temp_folder = temp_dir;
	temp_folder += "\\";
	temp_folder += std::to_string(hash);
	return temp_folder;
}

std::string JoinPath(const char* dir, const char* name)
{
	std::string path = dir;
	path += "\\";
	path += name;
	return path;
}

bool CacheComplete(const char* cache_dir)
{
	return PathFileExistsA(JoinPath(cache_dir, kCompleteFlagName).c_str()) != FALSE;
}

// Returns true if the command must be re-run (cache missing, incomplete, or stale).
bool CheckIfOutOfDate(const char* cache_dir)
{
	if (!DirectoryExists(cache_dir))
	{
		CreateDirectoryA(cache_dir, NULL);
		return true;
	}

	// Without a completion sentinel, an empty/partial cache after ClearCacheDir
	// must never be treated as up-to-date.
	if (!CacheComplete(cache_dir))
	{
		DebugPrint("Cache incomplete (missing %s)\n", kCompleteFlagName);
		return true;
	}

	auto check_mtime_list = [](const char* list_path, const char* label) -> bool
	{
		std::ifstream files(list_path);
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
			FILETIME filetime_now = GetFileModifiedTime(wide_path.c_str());
			const uint64_t filetime_now_u64 = FileTimeToUInt64(filetime_now);
			if (filetime_now_u64 != filetime_before_u64)
			{
				DebugPrint("File modified since last run (%s): %s\n", label, path.c_str());
				return true;
			}
		}
		return false;
	};

	if (check_mtime_list(JoinPath(cache_dir, kReadFilesName).c_str(), kReadFilesName))
	{
		return true;
	}
	if (check_mtime_list(JoinPath(cache_dir, kWriteFilesName).c_str(), kWriteFilesName))
	{
		return true;
	}
	return false;
}

std::string BuildTrackerCommandLine(const char* tracker_path, const char* cache_folder, const char* command_line)
{
	std::stringstream s;
	s << "\"" << tracker_path << "\"" << " /i \"" << cache_folder << "\" /c ";
	s << command_line;
	return s.str();
}

DWORD RunCommand(std::string& cmd)
{
	DebugPrint("Running command: %s\n", cmd.c_str());
	STARTUPINFOA si;
	PROCESS_INFORMATION pi;

	ZeroMemory(&si, sizeof(si));
	si.cb = sizeof(si);
	ZeroMemory(&pi, sizeof(pi));

	// Start the child process.
	if (!CreateProcessA(NULL,   // No module name (use command line)
		cmd.data(), // Command line (mutable buffer required by CreateProcessA)
		NULL,       // Process handle not inheritable
		NULL,       // Thread handle not inheritable
		FALSE,      // Set handle inheritance to FALSE
		0,          // No creation flags
		NULL,       // Use parent's environment block
		NULL,       // Use parent's starting directory
		&si,        // Pointer to STARTUPINFO structure
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
// include a final line that lacks a trailing newline.
template <typename LAMBDA_PER_LINE>
void ProcessUTF16FileByLine(const char* pFile, LAMBDA_PER_LINE lambda)
{
	static_assert(sizeof(wchar_t) == 2);
	FILE* f = fopen(pFile, "rb");
	if (!f)
	{
		DebugPrint("Failed to open file for reading: %s\n", pFile);
		return;
	}
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (len <= 0)
	{
		fclose(f);
		return;
	}
	if ((len % (long)sizeof(wchar_t)) != 0)
	{
		DebugPrint("UTF-16 file has odd byte length, truncating: %s\n", pFile);
		len -= (len % (long)sizeof(wchar_t));
	}
	// +1 wchar_t so a final line without a newline can be null-terminated in place.
	wchar_t* data = (wchar_t*)malloc((size_t)len + sizeof(wchar_t));
	if (!data)
	{
		DebugPrint("malloc failed to allocate %i bytes\n", len);
		fclose(f);
		return;
	}
	const size_t bytes_read = fread(data, 1, (size_t)len, f);
	fclose(f);
	if (bytes_read != (size_t)len)
	{
		DebugPrint("Short read on %s (%zu of %ld bytes)\n", pFile, bytes_read, len);
		free(data);
		return;
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
}

void ClearCacheDir(const char* cache_dir)
{
	DebugPrint("Clearing cache directory %s\n", cache_dir);
	std::error_code ec;
	if (!std::filesystem::exists(cache_dir, ec))
	{
		return;
	}
	for (const auto& entry : std::filesystem::directory_iterator(cache_dir, ec))
	{
		std::filesystem::remove_all(entry.path(), ec);
	}
}

bool WriteUtf8FileAtomic(const char* final_path, const std::string& contents)
{
	std::string temp_path = final_path;
	temp_path += ".tmp";

	{
		std::ofstream out(temp_path, std::ios::binary | std::ios::trunc);
		if (!out.good())
		{
			DebugPrint("Failed to open temp cache file: %s\n", temp_path.c_str());
			return false;
		}
		out.write(contents.data(), (std::streamsize)contents.size());
		if (!out.good())
		{
			DebugPrint("Failed to write temp cache file: %s\n", temp_path.c_str());
			return false;
		}
	}

	if (!MoveFileExA(temp_path.c_str(), final_path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
	{
		DebugPrint("Failed to publish cache file %s (%lu)\n", final_path, GetLastError());
		DeleteFileA(temp_path.c_str());
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

bool BuildCacheFile(const char* cache_dir)
{
	std::unordered_map<std::wstring, FILETIME> read_files;
	std::unordered_map<std::wstring, FILETIME> write_files;
	std::error_code ec;
	for (const auto& entry : std::filesystem::directory_iterator(cache_dir, ec))
	{
		if (entry.path().extension() != L".tlog")
		{
			continue;
		}

		DebugPrint("Processing file: %ls\n", entry.path().c_str());
		std::unordered_map<std::wstring, FILETIME>* map_files =
			IsWriteTlogFilename(entry.path()) ? &write_files : &read_files;

		const std::string tlog_path_utf8 = WideToUtf8(entry.path().wstring());
		ProcessUTF16FileByLine(tlog_path_utf8.c_str(), [&](wchar_t* line)
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
					FILETIME ft = GetFileModifiedTime(line);
					map_files->emplace(std::move(wstr), ft);
					DebugPrint("\t%ls\n", line);
				}
			});

		DeleteFileW(entry.path().c_str());
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

	const std::string read_path = JoinPath(cache_dir, kReadFilesName);
	const std::string write_path = JoinPath(cache_dir, kWriteFilesName);
	const std::string complete_path = JoinPath(cache_dir, kCompleteFlagName);

	// Ensure a prior incomplete publish cannot leave a stale sentinel.
	DeleteFileA(complete_path.c_str());

	if (!WriteUtf8FileAtomic(read_path.c_str(), serialize_map(read_files)))
	{
		return false;
	}
	if (!WriteUtf8FileAtomic(write_path.c_str(), serialize_map(write_files)))
	{
		return false;
	}

	// Sentinel last: only present when both cache files were published successfully.
	if (!WriteUtf8FileAtomic(complete_path.c_str(), "ok\n"))
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

// Return the arg and its index in GetCommandLine
std::pair<std::string, int> GetCommandToRun(size_t arg_idx)
{
	// We use GetCommandLineA here rather than params passed to main because argv has the quotes stripped.
	LPSTR pCommandLine = GetCommandLineA();

	size_t length = strlen(pCommandLine);

	// Find where the arg_idx begins
	int arg_start = 0;
	int arg_cnt = 0;
	int quote_cnt = 0;
	for (int i = 0; i < (int)length; i++)
	{
		if (pCommandLine[i] == '\"')
		{
			quote_cnt++;
		}
		else if (pCommandLine[i] == ' ' && (quote_cnt % 2) == 0)
		{
			//Skip ahead any additional spaces in the command line
			while (pCommandLine[i] == ' ')
			{
				i++;
			}
			i--;

			if (arg_cnt == (int)arg_idx)
			{
				return { std::string(&(pCommandLine[arg_start]), i - arg_start), arg_start };
			}
			arg_start = i + 1;
			arg_cnt++;
		}
	}
	return { std::string(&(pCommandLine[arg_start]), length - arg_start), arg_start };
}

int main(int argc, char* argv[])
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

	std::string tracker_path(argv[1]);
	tracker_path += "\\Tracker.exe";

	// We use GetCommandLineA here rather than params passed to main because argv has the quotes stripped.
	std::string command_line = GetCommandLineA() + GetCommandToRun(3).second;

	// Generate unique hash from command to run.
	const std::hash<std::string> string_hasher;
	const size_t command_line_hash = string_hasher(command_line);

	// Build a unique folder to put cache files based on the command line
	const std::string cache_dir = GetTempDir(argv[2], command_line_hash);
	if (CheckIfOutOfDate(cache_dir.c_str()))
	{
		ClearCacheDir(cache_dir.c_str()); // Clear any cache files from previous run
		std::string cmd = BuildTrackerCommandLine(tracker_path.c_str(), cache_dir.c_str(), command_line.c_str());
		const DWORD ret = RunCommand(cmd);
		if (ret == 0)
		{
			// Process succeeded, process and write cache files.
			if (!BuildCacheFile(cache_dir.c_str()))
			{
				ClearCacheDir(cache_dir.c_str());
				DebugPrint("Failed to publish cache; cleared incomplete cache dir.\n");
				return -1;
			}
		}
		else
		{
			// Process returned error exit code. Clear cache dir.
			ClearCacheDir(cache_dir.c_str());
		}
		return ret;
	}
	// We are up to date!
	DebugPrint("Command is up to date. Exiting.\n");
	return 0;
}
