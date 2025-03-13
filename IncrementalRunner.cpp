#define _SILENCE_CXX17_CODECVT_HEADER_DEPRECATION_WARNING
#define _CRT_SECURE_NO_WARNINGS
#include <algorithm>
#include <chrono>
#include <codecvt>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <locale>
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

//https://stackoverflow.com/questions/6218325/how-do-you-check-if-a-directory-exists-on-windows-in-c
BOOL DirectoryExists(LPCSTR szPath)
{
	DWORD dwAttrib = GetFileAttributesA(szPath);
	return (dwAttrib != INVALID_FILE_ATTRIBUTES && (dwAttrib & FILE_ATTRIBUTE_DIRECTORY));
}

static_assert(sizeof(FILETIME) == sizeof(uint64_t));
FILETIME GetFileModifiedTime(LPCWSTR lpFileName)
{
	HANDLE hFile;
	FILETIME CreationTime;
	FILETIME LastAccessTime;
	FILETIME LastWriteTime;

	hFile = CreateFile(lpFileName, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
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

FILETIME GetFileModifiedTimeA(LPCSTR lpFileName)
{
	HANDLE hFile;
	FILETIME CreationTime;
	FILETIME LastAccessTime;
	FILETIME LastWriteTime;

	hFile = CreateFileA(lpFileName, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
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

bool CheckIfOutOfDate(const char* cache_dir)
{
	if (!DirectoryExists(cache_dir))
	{
		CreateDirectoryA(cache_dir, NULL);
		return true;
	}

	// Process read files - Check modified times have not changed
	{
		std::string chache_read_file = cache_dir;
		chache_read_file += "\\readfiles.txt";
		std::ifstream readfiles(chache_read_file);
		if (readfiles.good())
		{
			std::string path, filetime;
			while (std::getline(readfiles, path))
			{
				if (std::getline(readfiles, filetime))
				{
					uint64_t filetime_before_u64 = std::stoull(filetime.c_str());
					FILETIME filetime_now = GetFileModifiedTimeA(path.c_str());
					uint64_t filetime_now_u64 = *(uint64_t*)&filetime_now;
					if (filetime_now_u64 != filetime_before_u64)
					{
						DebugPrint("File modified since last run: %s\n", path.c_str());
						return true;
					}
				}
			}
		}
	}

	// Process write files - Ensure they exist
	{
		std::string chache_write_file = cache_dir;
		chache_write_file += "\\writefiles.txt";
		std::ifstream writefiles(chache_write_file);
		if (writefiles.good())
		{
			std::string path, filetime;
			while (std::getline(writefiles, path))
			{
				if (std::getline(writefiles, filetime))
				{
					if (PathFileExistsA(path.c_str()) == false)
					{
						return true;
					}
				}
			}
		}
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

DWORD RunCommand(char* cmd)
{
	DebugPrint("Running command: %s\n", cmd);
	STARTUPINFOA si;
	PROCESS_INFORMATION pi;

	ZeroMemory(&si, sizeof(si));
	si.cb = sizeof(si);
	ZeroMemory(&pi, sizeof(pi));

	// Start the child process. 
	if (!CreateProcessA(NULL,   // No module name (use command line)
		cmd,        // Command line
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

// The file written by Tracker.exe is a UTF16 text file with initial data a BOM
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
	wchar_t* data = (wchar_t*)malloc(len);
	if (!data)
	{
		DebugPrint("malloc failed to allocate %i bytes\n", len);
		fclose(f);
		return;
	}
	fread(data, len, 1, f);
	fclose(f);
	long characters = len / sizeof(wchar_t);
	long start = 0;
	for (long i = 0; i < characters; i++)
	{
		if (data[i] == (wchar_t)0xFEFF) // Check for BOM
		{
			start++;
			continue;
		}

		if (data[i] == L'\r')
		{
			data[i] = L'\0';
			lambda(&(data[start]));
			start = i + 2; // Skip to start of next line
		}

	}
	free(data);
}

void ClearCacheDir(const char* cache_dir)
{
	DebugPrint("Clearing cache directory %s\n", cache_dir);
	if (std::filesystem::exists(cache_dir))
	{
		for (const auto& entry : std::filesystem::directory_iterator(cache_dir))
		{
			DeleteFile(entry.path().c_str());
		}
	}
}

void BuildCacheFile(const char* cache_dir)
{
	std::unordered_map<std::wstring, FILETIME> read_files;
	std::unordered_map<std::wstring, FILETIME> write_files;
	for (const auto& entry : std::filesystem::directory_iterator(cache_dir))
	{
		if (entry.path().extension() == L".tlog")
		{
			DebugPrint("Processing file: %ls\n", entry.path().c_str());
			std::unordered_map<std::wstring, FILETIME>* map_files = &read_files;
			if (strstr(entry.path().u8string().c_str(), ".write.") != nullptr) map_files = &write_files;

			ProcessUTF16FileByLine(entry.path().u8string().c_str(), [&](wchar_t* line)
				{
					if (line[0] != L'#')
					{
						std::wstring wstr(line);
						auto it = map_files->find(wstr);
						if (it == map_files->end())
						{
							FILETIME ft = GetFileModifiedTime(line);
							map_files->emplace(std::move(wstr), ft);
							DebugPrint("\t%ls\n", line);
						}
					}
				});

			// delete the .tlog file
			DeleteFile(entry.path().c_str());
		}
	}

	// Output read files
	{
		std::string read_file_path = cache_dir;
		read_file_path += "\\readfiles.txt";
		std::wofstream read_file(read_file_path);
		for (auto& f : read_files)
		{
			read_file << f.first << L"\n";
			read_file << std::to_wstring(*((uint64_t*)&f.second)) << L"\n";
		}
	}

	// Output write files
	{
		std::string write_file_path = cache_dir;
		write_file_path += "\\writefiles.txt";
		std::wofstream read_file(write_file_path);
		for (auto& f : write_files)
		{
			read_file << f.first << L"\n";
			read_file << std::to_wstring(*((uint64_t*)&f.second)) << L"\n";
		}
	}
}

void PrintUsage()
{
	printf("Arg 0: Cache Directory");
	printf("Arg 1: Command Line (Don't do anything special here, just pass it as if you were going to call it normally)");
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
	for (int i = 0; i < length; i++)
	{
		if (pCommandLine[i] == '\"')
		{
			quote_cnt++;
		}
		else if (pCommandLine[i] == ' ' && (quote_cnt % 2) == 0)
		{
			if (arg_cnt == arg_idx)
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
	const char* tracker_path = "Tracker.exe";
	if (argc > 1)
	{
		// We use GetCommandLineA here rather than params passed to main because argv has the quotes stripped.
		std::string command_line = GetCommandLineA() + GetCommandToRun(2).second;

		// Generate unique hash from command to run.
		const std::hash<std::string> string_hasher;
		const size_t command_line_hash = string_hasher(command_line);

		// Build a unique folder to put cache files based on the command line
		const std::string cache_dir = GetTempDir(argv[1], command_line_hash);
		if (CheckIfOutOfDate(cache_dir.c_str()))
		{
			ClearCacheDir(cache_dir.c_str()); // Clear any cache files from previous run
			const std::string cmd = BuildTrackerCommandLine(tracker_path, cache_dir.c_str(), command_line.c_str());
			const DWORD ret = RunCommand((char*)cmd.c_str());
			if (ret == 0)
			{
				// Process succeeded, process and write cache files.
				BuildCacheFile(cache_dir.c_str());
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
	PrintUsage();
	return -1;
}