/****************************************************************************
** Meta object code from reading C++ file 'PropertyPanel.hpp'
**
** Created by: The Qt Meta Object Compiler version 69 (Qt 6.11.1)
**
** WARNING! All changes made in this file will be lost!
*****************************************************************************/

#include "../../../../gui/include/cadnext/gui/PropertyPanel.hpp"
#include <QtCore/qmetatype.h>

#include <QtCore/qtmochelpers.h>

#include <memory>


#include <QtCore/qxptype_traits.h>
#if !defined(Q_MOC_OUTPUT_REVISION)
#error "The header file 'PropertyPanel.hpp' doesn't include <QObject>."
#elif Q_MOC_OUTPUT_REVISION != 69
#error "This file was generated using the moc from 6.11.1. It"
#error "cannot be used with the include files from this version of Qt."
#error "(The moc has changed too much.)"
#endif

#ifndef Q_CONSTINIT
#define Q_CONSTINIT
#endif

QT_WARNING_PUSH
QT_WARNING_DISABLE_DEPRECATED
QT_WARNING_DISABLE_GCC("-Wuseless-cast")
namespace {
struct qt_meta_tag_ZN7cadnext3gui13PropertyPanelE_t {};
} // unnamed namespace

template <> constexpr inline auto cadnext::gui::PropertyPanel::qt_create_metaobjectdata<qt_meta_tag_ZN7cadnext3gui13PropertyPanelE_t>()
{
    namespace QMC = QtMocConstants;
    QtMocHelpers::StringRefStorage qt_stringData {
        "cadnext::gui::PropertyPanel",
        "nameEdited",
        "",
        "objectId",
        "newName",
        "sketchNameEdited",
        "sketchId",
        "entityNameEdited",
        "entityId",
        "transformEdited",
        "cadnext::Transform",
        "transform",
        "primitiveEdited",
        "cadnext::PrimitiveParameters",
        "parameters"
    };

    QtMocHelpers::UintData qt_methods {
        // Signal 'nameEdited'
        QtMocHelpers::SignalData<void(const QString &, const QString &)>(1, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::QString, 3 }, { QMetaType::QString, 4 },
        }}),
        // Signal 'sketchNameEdited'
        QtMocHelpers::SignalData<void(const QString &, const QString &)>(5, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::QString, 6 }, { QMetaType::QString, 4 },
        }}),
        // Signal 'entityNameEdited'
        QtMocHelpers::SignalData<void(const QString &, const QString &, const QString &)>(7, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::QString, 6 }, { QMetaType::QString, 8 }, { QMetaType::QString, 4 },
        }}),
        // Signal 'transformEdited'
        QtMocHelpers::SignalData<void(const QString &, const cadnext::Transform &)>(9, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::QString, 3 }, { 0x80000000 | 10, 11 },
        }}),
        // Signal 'primitiveEdited'
        QtMocHelpers::SignalData<void(const QString &, const cadnext::PrimitiveParameters &)>(12, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::QString, 3 }, { 0x80000000 | 13, 14 },
        }}),
    };
    QtMocHelpers::UintData qt_properties {
    };
    QtMocHelpers::UintData qt_enums {
    };
    return QtMocHelpers::metaObjectData<PropertyPanel, qt_meta_tag_ZN7cadnext3gui13PropertyPanelE_t>(QMC::MetaObjectFlag{}, qt_stringData,
            qt_methods, qt_properties, qt_enums);
}
Q_CONSTINIT const QMetaObject cadnext::gui::PropertyPanel::staticMetaObject = { {
    QMetaObject::SuperData::link<QWidget::staticMetaObject>(),
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN7cadnext3gui13PropertyPanelE_t>.stringdata,
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN7cadnext3gui13PropertyPanelE_t>.data,
    qt_static_metacall,
    nullptr,
    qt_staticMetaObjectRelocatingContent<qt_meta_tag_ZN7cadnext3gui13PropertyPanelE_t>.metaTypes,
    nullptr
} };

void cadnext::gui::PropertyPanel::qt_static_metacall(QObject *_o, QMetaObject::Call _c, int _id, void **_a)
{
    auto *_t = static_cast<PropertyPanel *>(_o);
    if (_c == QMetaObject::InvokeMetaMethod) {
        switch (_id) {
        case 0: _t->nameEdited((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<QString>>(_a[2]))); break;
        case 1: _t->sketchNameEdited((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<QString>>(_a[2]))); break;
        case 2: _t->entityNameEdited((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<QString>>(_a[2])),(*reinterpret_cast<std::add_pointer_t<QString>>(_a[3]))); break;
        case 3: _t->transformEdited((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<cadnext::Transform>>(_a[2]))); break;
        case 4: _t->primitiveEdited((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<cadnext::PrimitiveParameters>>(_a[2]))); break;
        default: ;
        }
    }
    if (_c == QMetaObject::IndexOfMethod) {
        if (QtMocHelpers::indexOfMethod<void (PropertyPanel::*)(const QString & , const QString & )>(_a, &PropertyPanel::nameEdited, 0))
            return;
        if (QtMocHelpers::indexOfMethod<void (PropertyPanel::*)(const QString & , const QString & )>(_a, &PropertyPanel::sketchNameEdited, 1))
            return;
        if (QtMocHelpers::indexOfMethod<void (PropertyPanel::*)(const QString & , const QString & , const QString & )>(_a, &PropertyPanel::entityNameEdited, 2))
            return;
        if (QtMocHelpers::indexOfMethod<void (PropertyPanel::*)(const QString & , const cadnext::Transform & )>(_a, &PropertyPanel::transformEdited, 3))
            return;
        if (QtMocHelpers::indexOfMethod<void (PropertyPanel::*)(const QString & , const cadnext::PrimitiveParameters & )>(_a, &PropertyPanel::primitiveEdited, 4))
            return;
    }
}

const QMetaObject *cadnext::gui::PropertyPanel::metaObject() const
{
    return QObject::d_ptr->metaObject ? QObject::d_ptr->dynamicMetaObject() : &staticMetaObject;
}

void *cadnext::gui::PropertyPanel::qt_metacast(const char *_clname)
{
    if (!_clname) return nullptr;
    if (!strcmp(_clname, qt_staticMetaObjectStaticContent<qt_meta_tag_ZN7cadnext3gui13PropertyPanelE_t>.strings))
        return static_cast<void*>(this);
    return QWidget::qt_metacast(_clname);
}

int cadnext::gui::PropertyPanel::qt_metacall(QMetaObject::Call _c, int _id, void **_a)
{
    _id = QWidget::qt_metacall(_c, _id, _a);
    if (_id < 0)
        return _id;
    if (_c == QMetaObject::InvokeMetaMethod) {
        if (_id < 5)
            qt_static_metacall(this, _c, _id, _a);
        _id -= 5;
    }
    if (_c == QMetaObject::RegisterMethodArgumentMetaType) {
        if (_id < 5)
            *reinterpret_cast<QMetaType *>(_a[0]) = QMetaType();
        _id -= 5;
    }
    return _id;
}

// SIGNAL 0
void cadnext::gui::PropertyPanel::nameEdited(const QString & _t1, const QString & _t2)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 0, nullptr, _t1, _t2);
}

// SIGNAL 1
void cadnext::gui::PropertyPanel::sketchNameEdited(const QString & _t1, const QString & _t2)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 1, nullptr, _t1, _t2);
}

// SIGNAL 2
void cadnext::gui::PropertyPanel::entityNameEdited(const QString & _t1, const QString & _t2, const QString & _t3)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 2, nullptr, _t1, _t2, _t3);
}

// SIGNAL 3
void cadnext::gui::PropertyPanel::transformEdited(const QString & _t1, const cadnext::Transform & _t2)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 3, nullptr, _t1, _t2);
}

// SIGNAL 4
void cadnext::gui::PropertyPanel::primitiveEdited(const QString & _t1, const cadnext::PrimitiveParameters & _t2)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 4, nullptr, _t1, _t2);
}
QT_WARNING_POP
