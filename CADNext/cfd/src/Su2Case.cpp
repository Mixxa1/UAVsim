#include "cadnext/cfd/Su2Case.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <sstream>
#include <thread>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#include <sys/wait.h>
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <csignal>
#include <chrono>
#include <thread>
#include <cerrno>
#include <cstring>
#include <set>

extern char** environ;

namespace cadnext::cfd {

int recommendedSolverThreads() {
#if defined(__APPLE__)
    int cores = 0;
    std::size_t size = sizeof(cores);
    if (sysctlbyname("hw.perflevel0.logicalcpu", &cores, &size, nullptr, 0) == 0 && cores > 0) return cores;
#endif
    const unsigned hardware = std::thread::hardware_concurrency();
    return hardware > 0 ? static_cast<int>(hardware) : 1;
}


void Su2Config::set(const std::string& key, const std::string& value) {
    for (auto& [existing, current] : entries) {
        if (existing == key) {
            current = value;
            return;
        }
    }
    entries.emplace_back(key, value);
}

std::string Su2Config::text() const {
    std::string out;
    for (const auto& [key, value] : entries) out += key + "= " + value + "\n";
    return out;
}

int Su2History::column(const std::string& name) const {
    const auto found = std::find(columns.begin(), columns.end(), name);
    return found == columns.end() ? -1 : static_cast<int>(found - columns.begin());
}

double Su2History::last(const std::string& name) const {
    const int c = column(name);
    if (c < 0 || rows.empty() || rows.back().size() <= static_cast<std::size_t>(c)) return std::numeric_limits<double>::quiet_NaN();
    return rows.back()[c];
}

double Su2History::relativeSpread(const std::string& name, int window) const {
    const int c = column(name);
    if (c < 0 || window <= 0 || rows.size() < static_cast<std::size_t>(window)) return std::numeric_limits<double>::quiet_NaN();
    const std::size_t first = rows.size() > static_cast<std::size_t>(window) ? rows.size() - window : 0;
    double low = rows.back()[c], high = low;
    for (std::size_t r = first; r < rows.size(); ++r) {
        low = std::min(low, rows[r][c]);
        high = std::max(high, rows[r][c]);
    }
    const double scale = std::fabs(rows.back()[c]);
    return scale > 0.0 ? (high - low) / scale : high - low;
}

Result<Su2History> parseSu2History(const std::string& text) {
    Su2History history;
    std::istringstream stream(text);
    std::string line;
    auto split = [](const std::string& row) {
        std::vector<std::string> cells;
        std::string cell;
        std::istringstream in(row);
        while (std::getline(in, cell, ',')) {
            cell.erase(std::remove(cell.begin(), cell.end(), '"'), cell.end());
            const auto first = cell.find_first_not_of(" \t\r");
            const auto last = cell.find_last_not_of(" \t\r");
            cells.push_back(first == std::string::npos ? "" : cell.substr(first, last - first + 1));
        }
        return cells;
    };
    if (!std::getline(stream, line)) return Result<Su2History>::fail({ErrorCode::SerializationFailed, "история SU2 пуста"});
    history.columns = split(line);
    const std::set<std::string> unique(history.columns.begin(), history.columns.end());
    if (history.columns.empty() || unique.size() != history.columns.size() || unique.contains(""))
        return Result<Su2History>::fail({ErrorCode::SerializationFailed, "неверный заголовок CSV SU2"});
    while (std::getline(stream, line)) {
        if (line.find_first_not_of(" \t\r") == std::string::npos) continue;
        const auto cells = split(line);
        if (cells.size() != history.columns.size()) return Result<Su2History>::fail({ErrorCode::SerializationFailed, "неполная строка CSV SU2"});
        std::vector<double> row;
        for (const auto& cell : cells) {
            char* end = nullptr;
            const double value = std::strtod(cell.c_str(), &end);
            if (end == cell.c_str() || *end != '\0' || !std::isfinite(value))
                return Result<Su2History>::fail({ErrorCode::SerializationFailed, "нечисловое или неограниченное значение CSV SU2"});
            row.push_back(value);
        }
        history.rows.push_back(std::move(row));
    }
    return Result<Su2History>::ok(std::move(history));
}

Result<Su2RunResult> runSu2(const std::string& solver, const std::string& directory, const Su2Config& config, int threads,
                                const Su2RunControl& control) {
    namespace fs = std::filesystem;
    auto fail = [](const std::string& message) { return Result<Su2RunResult>::fail({ErrorCode::KernelOperationFailed, message}); };
    if (threads < 1 || threads > 256 || !std::isfinite(control.timeoutSeconds) || control.timeoutSeconds <= 0)
        return fail("неверное число потоков или время расчёта SU2");
    std::error_code ec;
    const auto executable = fs::absolute(solver, ec);
    if (ec || access(executable.c_str(), X_OK) != 0) return fail("SU2_CFD не найден или не исполняемый: " + solver);
    const auto work = fs::absolute(directory, ec);
    if (ec || !fs::is_directory(work)) return fail("нет каталога расчёта SU2");
    if (control.cancel && control.cancel()) { Su2RunResult r; r.cancelled = true; return Result<Su2RunResult>::ok(r); }
    // Never collect a previous attempt's history after a failed launch.
    fs::remove(work / "history.csv", ec);
    if (ec) return fail("не удалось очистить предыдущую историю SU2");
    {
        std::ofstream file(work / "case.cfg", std::ios::binary | std::ios::trunc);
        if (!file || !(file << config.text())) return fail("не удалось записать конфигурацию SU2");
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int setup = posix_spawn_file_actions_addchdir_np(&actions, work.c_str());
    if (!setup) setup = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "su2.log", O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (!setup) setup = posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    if (!setup) setup = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attributes, 0);
    std::string executableText = executable.string(), count = std::to_string(threads);
    char* argv[] = {executableText.data(), const_cast<char*>("-t"), count.data(), const_cast<char*>("case.cfg"), nullptr};
    pid_t pid = -1;
    const int error = setup ? setup : posix_spawn(&pid, executable.c_str(), &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (error) return fail(std::string("не удалось запустить SU2: ") + std::strerror(error));
    struct ChildGuard {
        pid_t pid;
        ~ChildGuard() { if (pid > 0) { kill(-pid, SIGKILL); int status; while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {} } }
    } child{pid};
    Su2RunResult result;
    const auto start = std::chrono::steady_clock::now();
    auto stopTime = start;
    bool stopping = false;
    int status = 0;
    std::size_t reported = 0;
    for (;;) {
        const auto waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) { child.pid = -1; break; }
        if (waited < 0 && errno != EINTR) { kill(-pid, SIGKILL); waitpid(pid, &status, 0); child.pid = -1; return fail("не удалось дождаться SU2"); }
        const auto now = std::chrono::steady_clock::now();
        if (!stopping) {
            result.cancelled = control.cancel && control.cancel();
            result.timedOut = std::chrono::duration<double>(now - start).count() >= control.timeoutSeconds;
            if (result.cancelled || result.timedOut) { kill(-pid, SIGTERM); stopping = true; stopTime = now; }
        } else if (now - stopTime > std::chrono::seconds(2)) { kill(-pid, SIGKILL); }
        if (control.progress && !stopping) {
            std::ifstream file(work / "history.csv");
            std::string csv{std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
            const auto newline = csv.find_last_of('\n'); // the solver may be writing the final row
            if (newline != std::string::npos) {
                auto history = parseSu2History(csv.substr(0, newline + 1));
                if (history.isOk() && history.value().rows.size() > reported) {
                    reported = history.value().rows.size();
                    control.progress(history.value());
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    result.exitStatus = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1);
    {
        std::ifstream log(work / "su2.log", std::ios::binary);
        // Keep a useful tail in memory; the complete log stays on disk.
        log.seekg(0, std::ios::end);
        const std::streamoff size = log.tellg();
        log.seekg(size > 65536 ? size - std::streamoff(65536) : std::streamoff(0));
        result.log.assign(std::istreambuf_iterator<char>(log), std::istreambuf_iterator<char>());
    }
    if (result.cancelled || result.timedOut || result.exitStatus != 0) return Result<Su2RunResult>::ok(std::move(result));
    std::ifstream file(work / "history.csv");
    if (!file) return fail("SU2 не записал историю; см. su2.log");
    auto history = parseSu2History({std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()});
    if (!history.isOk()) return Result<Su2RunResult>::fail(history.error());
    if (history.value().empty()) return fail("SU2 записал пустую историю");
    result.history = std::move(history.value());
    return Result<Su2RunResult>::ok(std::move(result));
}

} // namespace cadnext::cfd
