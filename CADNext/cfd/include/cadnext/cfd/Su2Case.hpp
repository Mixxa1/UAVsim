#pragma once

#include "cadnext/Result.hpp"

#include <map>
#include <functional>
#include <string>
#include <utility>
#include <vector>

// One SU2 calculation in its own folder: a configuration written from key/value pairs, SU2_CFD run as a
// separate process (a crashing solver never takes the caller down; cancelling is ending the
// process), and the convergence history read back.
//
// Convergence is judged from the history, never from wall time: a run that stopped at its iteration
// limit with the residual still falling is reported as such, not as a result.

namespace cadnext::cfd {

struct Su2Config {
    // Order kept as written, so the file reads like a hand-written configuration.
    std::vector<std::pair<std::string, std::string>> entries;

    void set(const std::string& key, const std::string& value);
    std::string text() const;
};

struct Su2History {
    std::vector<std::string> columns;
    std::vector<std::vector<double>> rows;

    bool empty() const { return rows.empty(); }
    int column(const std::string& name) const; // −1 when absent
    double last(const std::string& name) const; // NaN when absent
    // Largest |change| of a column over the last `window` rows, relative to |last value|.
    double relativeSpread(const std::string& name, int window) const;
};

Result<Su2History> parseSu2History(const std::string& csvText);

struct Su2RunResult {
    int exitStatus = -1;
    Su2History history;
    std::string log;
    bool cancelled = false;
    bool timedOut = false;
};

struct Su2RunControl {
    std::function<bool()> cancel;
    std::function<void(const Su2History&)> progress;
    double timeoutSeconds = 3600.0;
};

// Writes `config` (with MESH_FILENAME pointing at a mesh already in `directory`) and runs
// `solver` on `threads` OpenMP threads there.
// Threads worth giving SU2 on this machine: the performance cores. On a hybrid CPU the efficiency
// cores are several times slower, and every OpenMP barrier waits for the slowest thread, so counting
// all logical cores makes a run slower, not faster.
int recommendedSolverThreads();

Result<Su2RunResult> runSu2(const std::string& solver, const std::string& directory, const Su2Config& config, int threads,
                          const Su2RunControl& control = {});

} // namespace cadnext::cfd
