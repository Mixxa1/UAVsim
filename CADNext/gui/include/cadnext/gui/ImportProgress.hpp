#pragma once

#include <QString>

#include <atomic>
#include <functional>
#include <utility>

namespace cadnext::gui {

// How far a long import has got, told from the thread doing it (the sink decides where it goes: an
// ImportProgressDialog posts it to the UI thread), and whether the user asked to stop. Readers report
// and look for a stop between parts; a part being built is not interrupted.
class ImportProgress {
public:
    // `total` 0: a step whose length is not known (reading a STEP file).
    using Sink = std::function<void(int done, int total, const QString& step)>;

    explicit ImportProgress(Sink sink = {}) : sink_(std::move(sink)) {}
    ImportProgress(const ImportProgress&) = delete;
    ImportProgress& operator=(const ImportProgress&) = delete;

    void report(int done, int total, const QString& step) const {
        if (sink_) sink_(done, total, step);
    }
    void cancel() { cancelled_ = true; }
    bool cancelled() const { return cancelled_; }

private:
    Sink sink_;
    std::atomic<bool> cancelled_{false};
};

// The reason a reader gives when it stopped because cancelled() was set.
inline QString importCancelledReason() { return QStringLiteral("импорт отменён"); }

} // namespace cadnext::gui
