#include "cadnext/gui/CADPartLibraryService.hpp"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>

namespace cadnext::gui {

CADPartLibraryService& CADPartLibraryService::instance() {
    static CADPartLibraryService sInstance;
    return sInstance;
}

CADPartLibraryService::CADPartLibraryService() {
    const QString appData =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir dir(appData);
    dir.mkpath(QStringLiteral("."));
    indexPath_ = dir.filePath(QStringLiteral("parts_library.json"));
    load();
}

bool CADPartLibraryService::addPart(const QString& filePath) {
    if (paths_.contains(filePath)) {
        return true;
    }
    paths_.append(filePath);
    save();
    return true;
}

QStringList CADPartLibraryService::listedParts() const {
    return paths_;
}

void CADPartLibraryService::load() {
    QFile f(indexPath_);
    if (!f.open(QIODevice::ReadOnly)) {
        return;
    }
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isObject()) {
        return;
    }
    const QJsonArray arr = doc.object().value(QStringLiteral("parts")).toArray();
    for (const QJsonValue& v : arr) {
        const QString s = v.toString();
        if (!s.isEmpty()) {
            paths_.append(s);
        }
    }
}

void CADPartLibraryService::save() const {
    QJsonArray arr;
    for (const QString& p : paths_) {
        arr.append(p);
    }
    QJsonObject obj;
    obj[QStringLiteral("parts")] = arr;
    QFile f(indexPath_);
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(obj).toJson());
    }
}

} // namespace cadnext::gui
