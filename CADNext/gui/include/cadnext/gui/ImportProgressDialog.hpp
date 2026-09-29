#pragma once

#include "cadnext/gui/ImportProgress.hpp"

#include <QDialog>
#include <QElapsedTimer>
#include <QStringList>

#include <functional>

class QCloseEvent;
class QLabel;
class QProgressBar;
class QPushButton;

namespace cadnext::gui {

// A long import kept off the UI thread. `work` runs on a thread of its own and reports through
// progress(); the window shows the step and a bar, with a Stop button, while the UI stays live. Then
// `done` runs on the UI thread and the window keeps the outcome (finish()) until the user closes it.
// Closing the window while the work runs asks the work to stop instead; once the work is over the
// window deletes itself when closed.
class ImportProgressDialog : public QDialog {
public:
    ImportProgressDialog(const QString& title, QWidget* parent);

    ImportProgress& progress() { return progress_; }

    // `work` must not touch widgets: it runs on another thread. It is given what it needs by value.
    void run(std::function<void()> work, std::function<void()> done);

    // The outcome in the window: a headline and short lines, the bar full unless it failed.
    void finish(const QString& headline, const QStringList& lines, bool failed = false);

    // Seconds since run() started.
    double elapsedSeconds() const;

protected:
    void reject() override;
    void closeEvent(QCloseEvent* event) override;

private:
    void showStep(int done, int total, const QString& step);
    void stop();

    QLabel* step_ = nullptr;
    QProgressBar* bar_ = nullptr;
    QLabel* outcome_ = nullptr;
    QPushButton* button_ = nullptr;
    ImportProgress progress_;
    QElapsedTimer timer_;
    bool running_ = false;
};

} // namespace cadnext::gui
