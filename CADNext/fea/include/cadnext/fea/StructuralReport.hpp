#pragma once

#include <string>

namespace cadnext::fea {

// Self-contained HTML report (fea/report/structural-report.html) for one structural result:
// verdict, numbers with their mesh uncertainty, the 3D utilisation plot, convergence, load case,
// material. Takes the two files exactly as cadnext_structural writes them, so a report can also
// be rebuilt later from saved results.
std::string structuralReportHtml(const std::string& resultJson, const std::string& fieldJson);

// Same for a modal result (fea/report/modal-report.html): frequencies with their uncertainty
// against the excitation bands, animated mode shapes, mesh study, boundary and excitation.
std::string modalReportHtml(const std::string& resultJson, const std::string& fieldJson);

} // namespace cadnext::fea
