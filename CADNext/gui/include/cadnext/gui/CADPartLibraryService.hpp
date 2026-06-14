#pragma once

#include <QStringList>

namespace cadnext::gui {

// Локальная библиотека деталей: хранит список путей к .uavpart-файлам
// в ~/.cadnext/parts_library.json. Полный каталог с UI — следующий патч.
class CADPartLibraryService {
public:
    static CADPartLibraryService& instance();

    // Возвращает true, если файл добавлен (или уже есть в библиотеке).
    bool addPart(const QString& filePath);

    QStringList listedParts() const;

private:
    CADPartLibraryService();
    void load();
    void save() const;

    QString indexPath_;
    QStringList paths_;
};

} // namespace cadnext::gui
