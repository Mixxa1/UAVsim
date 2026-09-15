#pragma once

// Shared helpers for the structural-solver verification tests. Unlike `assert`, a failed
// check prints what was measured against what was expected and the test keeps going, so
// one run shows the whole table.

#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/LinearStatic.hpp"
#include "cadnext/fea/MeshGeneration.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace fea_test {

inline int& failures() {
    static int count = 0;
    return count;
}

inline void check(bool condition, const std::string& name, const std::string& detail = "") {
    if (condition) {
        std::printf("  PASS  %s\n", name.c_str());
    } else {
        ++failures();
        std::printf("  FAIL  %s%s%s\n", name.c_str(), detail.empty() ? "" : " — ", detail.c_str());
    }
}

inline void checkRelative(double measured, double reference, double tolerance, const std::string& name) {
    const double error = std::fabs(measured - reference) / std::fabs(reference);
    char detail[256];
    std::snprintf(detail, sizeof(detail), "measured %.6g, reference %.6g, error %.3f%% (tolerance %.3f%%)",
                  measured, reference, error * 100.0, tolerance * 100.0);
    check(error <= tolerance, name + ": " + detail, detail);
}

inline int finish(const char* testName) {
    if (failures() == 0) {
        std::printf("%s: OK\n", testName);
        return 0;
    }
    std::printf("%s: %d check(s) failed\n", testName, failures());
    return 1;
}

inline cadnext::fea::LinearStaticSolution solveOrDie(const cadnext::fea::LinearStaticProblem& problem,
                                                     const cadnext::fea::LinearStaticSettings& settings = {}) {
    const auto result = cadnext::fea::solveLinearStatic(problem, settings);
    if (!result.isOk()) {
        std::printf("  FAIL  solver error: %s\n", result.error().message.c_str());
        ++failures();
        std::exit(finish("solver"));
    }
    return result.value();
}

inline void printConvergence(const char* quantity, double coarse, double medium, double fine,
                             const cadnext::fea::ConvergenceEstimate& estimate) {
    std::printf("  %-28s coarse %.6g  medium %.6g  fine %.6g\n  %-28s %s\n", quantity, coarse, medium, fine, "",
                estimate.describe().c_str());
}

} // namespace fea_test
