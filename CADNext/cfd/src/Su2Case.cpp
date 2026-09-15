#include "cadnext/cfd/Su2Case.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <sstream>
#include <sys/wait.h>

namespace cadnext::cfd {

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
    if (c < 0 || rows.empty()) return std::numeric_limits<double>::quiet_NaN();
    return rows.back()[c];
}

double Su2History::relativeSpread(const std::string& name, int window) const {
    const int c = column(name);
    if (c < 0 || rows.empty()) return std::numeric_limits<double>::quiet_NaN();
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
    while (std::getline(stream, line)) {
        if (line.find_first_not_of(" \t\r") == std::string::npos) continue;
        const auto cells = split(line);
        if (cells.size() != history.columns.size()) continue;
        std::vector<double> row;
        for (const auto& cell : cells) {
            char* end = nullptr;
            const double value = std::strtod(cell.c_str(), &end);
            row.push_back(end == cell.c_str() ? std::numeric_limits<double>::quiet_NaN() : value);
        }
        history.rows.push_back(std::move(row));
    }
    return Result<Su2History>::ok(std::move(history));
}

Result<Su2RunResult> runSu2(const std::string& solver, const std::string& directory, const Su2Config& config, int threads) {
    namespace fs = std::filesystem;
    {
        std::ofstream file(fs::path(directory) / "case.cfg", std::ios::binary | std::ios::trunc);
        if (!file) return Result<Su2RunResult>::fail({ErrorCode::SerializationFailed, "не удалось записать конфигурацию SU2"});
        file << config.text();
    }
    const std::string command = "cd \"" + directory + "\" && \"" + solver + "\" -t " + std::to_string(threads) + " case.cfg > su2.log 2>&1";
    const int status = std::system(command.c_str());
    Su2RunResult result;
    result.exitStatus = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    {
        std::ifstream log(fs::path(directory) / "su2.log", std::ios::binary);
        result.log.assign(std::istreambuf_iterator<char>(log), std::istreambuf_iterator<char>());
    }
    std::ifstream historyFile(fs::path(directory) / "history.csv", std::ios::binary);
    if (!historyFile) {
        return Result<Su2RunResult>::fail({ErrorCode::KernelOperationFailed, "SU2 не записал историю (код " + std::to_string(result.exitStatus) + ")"});
    }
    const std::string historyText{std::istreambuf_iterator<char>(historyFile), std::istreambuf_iterator<char>()};
    auto history = parseSu2History(historyText);
    if (!history.isOk()) return Result<Su2RunResult>::fail(history.error());
    result.history = std::move(history.value());
    return Result<Su2RunResult>::ok(std::move(result));
}

} // namespace cadnext::cfd
