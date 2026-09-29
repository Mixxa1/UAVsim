#include "cadnext/gui/ImportProgressDialog.hpp"

#include <QCloseEvent>
#include <QHBoxLayout>
#include <QLabel>
#include <QMetaObject>
#include <QProgressBar>
#include <QPushButton>
#include <QThread>
#include <QVBoxLayout>

namespace cadnext::gui {

ImportProgressDialog::ImportProgressDialog(const QString& title, QWidget* parent)
    : QDialog(parent),
      progress_([this](int done, int total, const QString& step) {
          // From the worker thread: shown on the UI thread, in order.
          QMetaObject::invokeMethod(this, [this, done, total, step] { showStep(done, total, step); },
                                    Qt::QueuedConnection);
      }) {
    setWindowTitle(title);
    setWindowModality(Qt::WindowModal);
    setAttribute(Qt::WA_DeleteOnClose);
    setMinimumWidth(460);

    step_ = new QLabel(tr("Подготовка…"), this);
    step_->setWordWrap(true);
    bar_ = new QProgressBar(this);
    bar_->setRange(0, 0); // busy until the first count arrives
    bar_->setTextVisible(false);
    outcome_ = new QLabel(this);
    outcome_->setWordWrap(true);
    outcome_->setTextInteractionFlags(Qt::TextSelectableByMouse);
    outcome_->hide();
    button_ = new QPushButton(tr("Остановить"), this);
    connect(button_, &QPushButton::clicked, this, [this] {
        if (running_) stop();
        else close();
    });

    auto* buttons = new QHBoxLayout;
    buttons->addStretch();
    buttons->addWidget(button_);
    auto* layout = new QVBoxLayout(this);
    layout->addWidget(step_);
    layout->addWidget(bar_);
    layout->addWidget(outcome_);
    layout->addLayout(buttons);
}

void ImportProgressDialog::run(std::function<void()> work, std::function<void()> done) {
    running_ = true;
    timer_.start();
    QThread* thread = QThread::create(std::move(work));
    connect(thread, &QThread::finished, this, [this, thread, done = std::move(done)] {
        thread->deleteLater();
        running_ = false;
        button_->setEnabled(true);
        done();
    });
    show();
    thread->start();
}

void ImportProgressDialog::finish(const QString& headline, const QStringList& lines, bool failed) {
    step_->setText(headline);
    bar_->setRange(0, 1);
    bar_->setValue(failed ? 0 : 1);
    outcome_->setText(lines.join(QLatin1Char('\n')));
    outcome_->setVisible(!lines.isEmpty());
    button_->setText(tr("Закрыть"));
    button_->setEnabled(true);
    button_->setDefault(true);
    adjustSize();
}

double ImportProgressDialog::elapsedSeconds() const {
    return timer_.isValid() ? double(timer_.elapsed()) / 1000.0 : 0.0;
}

void ImportProgressDialog::showStep(int done, int total, const QString& step) {
    if (!running_) return;
    step_->setText(step);
    if (total > 0) {
        bar_->setRange(0, total);
        bar_->setValue(done);
    } else {
        bar_->setRange(0, 0);
    }
}

void ImportProgressDialog::stop() {
    progress_.cancel();
    button_->setEnabled(false);
    button_->setText(tr("Останавливается…"));
    step_->setText(tr("Останавливается после текущей детали…"));
}

void ImportProgressDialog::reject() {
    if (running_) stop();
    else QDialog::reject();
}

void ImportProgressDialog::closeEvent(QCloseEvent* event) {
    if (running_) {
        event->ignore();
        stop();
        return;
    }
    QDialog::closeEvent(event);
}

} // namespace cadnext::gui
