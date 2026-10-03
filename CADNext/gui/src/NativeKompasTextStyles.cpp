#include "cadnext/gui/NativeKompasTextStyles.hpp"

#include <QObject>

#include <cmath>
#include <cstring>
#include <stdexcept>

namespace cadnext::gui {
namespace {

using F = KompasStyleField;
F B(quint32 v) { return {F::Byte, v, 0, {}}; }
F H(quint32 v) { return {F::Half, v, 0, {}}; }
F W(quint32 v) { return {F::Word, v, 0, {}}; }
F R(float v) { return {F::Real, 0, v, {}}; }
F Z(quint32 n) { return {F::Zeros, n, 0, {}}; }
F T(const char16_t* text) { return {F::Text, 0, 0, QString::fromUtf16(text)}; }

struct Writer {
    QByteArray bytes;
    void number(quint64 value, int width) {
        for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void real(float value) {
        quint32 bits;
        std::memcpy(&bits, &value, sizeof bits);
        number(bits, 4);
    }
    void string(const QString& value) {
        number(quint64(value.size()), 4);
        for (const auto c : value) number(c.unicode(), 2);
    }
    void field(const F& f) {
        switch (f.kind) {
        case F::Byte: number(f.number, 1); return;
        case F::Half: number(f.number, 2); return;
        case F::Word: number(f.number, 4); return;
        case F::Real: real(f.real); return;
        case F::Zeros: bytes.append(int(f.number), '\0'); return;
        case F::Text: string(f.text); return;
        }
    }
};

struct Reader {
    const QByteArray& bytes;
    qsizetype at = 0;
    quint64 number(int width) {
        if (width > bytes.size() - at) throw std::runtime_error("truncated");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    float real() {
        const quint32 bits = quint32(number(4));
        float value;
        std::memcpy(&value, &bits, sizeof value);
        if (!std::isfinite(value)) throw std::runtime_error("real");
        return value;
    }
    QString string() {
        const auto count = number(4);
        if (count > 65536 || count * 2 > quint64(bytes.size() - at)) throw std::runtime_error("string");
        QString value;
        for (quint64 i = 0; i < count; ++i) value.append(QChar(ushort(number(2))));
        return value;
    }
    F field(const F& layout) {
        F f{layout.kind, 0, 0, {}};
        switch (layout.kind) {
        case F::Byte: f.number = quint32(number(1)); break;
        case F::Half: f.number = quint32(number(2)); break;
        case F::Word: f.number = quint32(number(4)); break;
        case F::Real: f.real = real(); break;
        case F::Zeros:
            for (quint32 i = 0; i < layout.number; ++i)
                if (number(1)) throw std::runtime_error("zeros");
            f.number = layout.number;
            break;
        case F::Text: f.text = string(); break;
        }
        return f;
    }
};

} // namespace

KompasTextStyleTable kompasDefaultTextStyles() {
    KompasTextStyleTable table;
    const auto style = [&](const char16_t* name, std::array<KompasTextLevel, 4> levels, const char16_t* font, quint32 kind, bool flag,
                           std::vector<F> extension) {
        table.styles.push_back({QString::fromUtf16(name), levels, QString::fromUtf16(font), kind, flag, std::move(extension)});
    };
    table.header = {R(1.0f), R(5.0f), R(2.0f), R(2.0f), H(2), R(5.0f), B(1), Z(1), B(1), Z(1), B(1), Z(1), H(1),
                    R(15.0f), R(12.0f), R(2.0f), H(1), R(7.0f), H(1), R(5.0f), B(1), Z(1)};
    style(u"Текст на чертеже", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {});
    style(u"Размерные надписи", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {});
    style(u"Шероховатость", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {});
    style(u"Линия-выноска #1", {{{true, 7.0f, 7.0f, 1.0f, 10.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {});
    style(u"Линия-выноска #2", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {});
    style(u"Линия-выноска #3", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {});
    style(u"Отклонения формы и база", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {});
    style(u"Заголовок таблицы ", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {});
    style(u"Ячейка таблицы ", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {});
    style(u"Название таблицы", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {
            R(5.0f)
        });
    style(u"Линия разреза/сечения", {{{true, 10.0f, 10.0f, 1.0f, 14.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 0, false, {});
    style(u"Стрелка вида", {{{true, 10.0f, 10.0f, 1.0f, 14.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 0, false, {});
    style(u"Обозначение изменения", {{{true, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 0, false, {});
    style(u"Фигурная скобка", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {});
    style(u"Номер узла", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {true, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 137, false, {});
    style(u"Марка координационной оси", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {
            T(u"GOST type A"), B(1), Z(1), B(1), Z(1), B(1), Z(1), B(1), Z(1), B(1), Z(1), B(1), Z(1), B(1),
            Z(1), B(1), Z(1), B(1), Z(1), B(1), Z(1), B(1), Z(1), W(1), W(1), W(1), Z(5), R(2.0f), B(64), H(1),
            R(6.0f), R(15.0f), R(6.0f), H(1), R(2.0f), R(1.5f), R(1.5f), R(5.0f), R(15.0f), H(1), R(0.5f), Z(2),
            B(1), Z(1), H(1), R(3.0f), R(2.0f), B(1), Z(1), T(u"АБВГДЕЖИКЛМНПРСТУФЦШЩЭЮЯ"), T(u"B"), R(15.0f),
            W(2), Z(16), W(1), Z(2), B(51), Z(1), T(u"51 1 71 0 73 0 75 0 53 1 124 1 0 1 77 0 78 0 50 1"), B(1),
            Z(1), W(1), W(1), Z(2), R(1.0f), R(2.0f), R(2.0f), R(1.0f), R(5.0f), R(3.0f), R(15.0f), B(1), Z(1),
            H(1), R(1.0f), R(2.0f), R(2.0f), R(1.0f), R(5.0f), R(3.0f), R(15.0f), B(1), Z(1), B(1), Z(1),
            T(u"79 1 84 0 85 0 86 0 80 1 81 1 82 1 83 1 89 0 90 0 0 1 87 0 88 0 50 1"),
            T(u"0 1 91 1 96 0 94 0 95 0 50 1"), W(79), Z(2), R(5.0f), Z(4),
            T(u"0 1 1 1 2 1 3 1 4 1 5 1 6 1 7 1 8 1 9 1 10 0 11 0 12 0 13 0 14 0 15 0 16 0 17 0 18 0 19 0 20 0 21 0 22 0 23 0"),
            Z(2), H(1), R(4.0f), R(3.0f), R(14.0f), Z(4), R(0.5f), R(0.5f), R(1.5f), R(1.0f), R(1.0f), R(1.0f),
            T(u"m"), Z(2), B(49), Z(1), B(32), Z(1), B(49), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49),
            Z(1), B(32), Z(1), B(52), Z(1), B(32), Z(1), B(49), Z(1), B(32), Z(1), B(53), Z(1), B(32), Z(1),
            B(48), Z(1), B(32), Z(1), B(50), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(51), Z(1), B(32),
            Z(1), B(48), Z(1), B(32), Z(1), B(54), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(55), Z(1),
            B(32), Z(1), B(48), Z(1), B(32), Z(1), B(56), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(57),
            Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(48), Z(1), B(32), Z(1), B(48), Z(1),
            B(32), Z(1), B(49), Z(1), B(49), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(50),
            Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(51), Z(1), B(32), Z(1), B(48), Z(1),
            B(32), Z(1), B(49), Z(1), B(52), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(53),
            Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(54), Z(1), B(32), Z(1), B(48), Z(1),
            B(32), Z(1), B(49), Z(1), B(55), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(56),
            Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(57), Z(1), B(32), Z(1), B(48), Z(1),
            B(32), Z(1), B(50), Z(1), B(48), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(50), Z(1), B(49),
            Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(50), Z(1), B(50), Z(1), B(32), Z(1), B(48), Z(1),
            B(32), Z(1), B(50), Z(1), B(51), Z(1), B(32), Z(1), W(48), R(1.0f), R(0.5f), R(1.0f), R(0.5f), B(1),
            Z(1), T(u"7"), Z(2), B(49), Z(1), B(48), Z(1), B(51), Z(1), B(32), Z(1), B(49), Z(1), B(32), Z(1),
            B(57), Z(1), B(55), Z(1), B(32), Z(1), B(49), Z(1), B(32), Z(1), B(49), Z(1), B(48), Z(1), B(50),
            Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(48), Z(1), B(52), Z(1), B(32), Z(1),
            B(48), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(32), Z(1), B(49), Z(1), B(48),
            Z(1), B(54), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(48), Z(1), B(53), Z(1),
            B(32), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(48), Z(1), B(48), Z(1), B(32), Z(1), B(48),
            Z(1), B(32), Z(1), B(49), Z(1), B(48), Z(1), B(49), Z(1), B(32), Z(1), B(48), Z(1), B(32), Z(1),
            B(53), Z(1), B(48), Z(1), B(32), Z(1), B(49), Z(1), B(1), Z(1), H(1), R(5.0f), R(3.0f), R(20.0f)
        });
    style(u"Выносная надпись", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {
            R(0.5f), R(0.5f), R(1.0f), R(1.0f)
        });
    style(u"Обозначение узла", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {
            R(10.0f), R(1.5f), W(1), T(u"АБВГДЖИКЛМНПРСТУФШЭЮЯ"), R(40.0f), R(40.0f), R(50.0f), R(50.0f),
            R(1.5f), R(1.5f), H(1), R(15.0f), R(20.0f), R(5.0f), R(15.0f), Z(4), W(1), R(5.0f), R(15.0f),
            R(0.5f), R(0.5f), R(1.0f), R(1.0f), B(1), Z(1)
        });
    style(u"Марка/позиционное обозначение с линией-выноской", {{{true, 7.0f, 7.0f, 1.0f, 10.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {
            T(u"0 1 109 1 114 0 115 0 116 0 110 0 111 0 112 0 113 0 119 0 120 0 117 0 118 0 50 1"), Z(4),
            T(u"51 1 71 0 73 0 75 0 53 1 0 1 77 0 78 0 50 1"), Z(2),
            T(u"51 1 71 0 73 0 75 0 53 1 0 1 77 0 78 0 50 1"), B(1), Z(1), H(2), R(5.0f), W(121), R(10.0f),
            R(2.0f), Z(2), R(5.0f), B(1), Z(1),
            T(u"9 1 1 1 0 0 2 0 3 0 4 0 5 0 6 0 7 0 8 0 10 0 11 0 12 0 13 0 14 0 15 0 16 0 17 0 18 0 19 0 20 0 21 0 22 0 23 0"),
            Z(2)
        });
    style(u"Марка/позиционное обозначение на линии", {{{true, 7.0f, 7.0f, 1.0f, 10.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {
            R(1.0f), R(1.0f)
        });
    style(u"Марка/позиционное обозначение без линии-выноски", {{{true, 3.5f, 3.5f, 1.0f, 10.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {
            Z(2),
            T(u"1 1 0 1 2 1 4 0 5 0 3 0 6 0 7 0 8 0 9 0 10 0 11 0 12 0 13 0 14 0 15 0 16 0 17 0 18 0 19 0 20 0 21 0 22 0 23 0"),
            Z(2), T(u"0 1 1 1 2 1 3 1 4 0 5 0 6 0 7 0 8 0 9 0 10 0 11 0"), R(5.0f), R(10.0f), R(10.0f), R(10.0f),
            R(15.0f), R(15.0f), R(20.0f), R(20.0f), R(5.0f), R(8.0f), R(20.0f), R(10.0f), R(10.0f), R(20.0f),
            R(0.5f), R(0.5f), W(1), Z(2), R(5.0f), R(3.0f), Z(2), B(1), Z(1), B(25), B(4), B(1), Z(1),
            T(u"Разрез")
        });
    style(u"Линия разреза", {{{true, 7.0f, 7.0f, 1.0f, 14.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 0, false, {
            R(10.0f),
            T(u"<?xml version=\"1.0\" encoding=\"utf-16\"?> \n<template> \n<curves> \n<curve offset=\"10.000000\"> \n<style id=\"0\" type=\"0\"/> \n</curve> \n<curve offset=\"0.000000\"> \n<style id=\"2\" type=\"0\"/> \n</curve> \n<curve offset=\"-10.000000\"> \n<style id=\"0\" type=\"0\"/> \n</curve> \n</curves> \n<tips> \n<begin type=\"0\" param=\"50.000000\"> \n<style id=\"0\" type=\"0\"/> \n</begin> \n<end type=\"0\" param=\"50.000000\"> \n<style id=\"0\" type=\"0\"/> \n</end> \n</tips> \n</template>")
        });
    style(u"Заголовок таблицы отчета", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {});
    style(u"Ячейка таблицы отчета", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 9, false, {});
    style(u"Название таблицы отчета", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {
            R(5.0f), B(1), Z(1), B(1), Z(1), B(1), Z(1), H(1), R(90.0f), R(2.0f), W(1), Z(2), B(0), Z(3)
        });
    style(u"Техтребования", {{{true, 3.5f, 3.5f, 1.0f, 5.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 11, true, {
            T(u"133 1 134 1 135 1 136 0 50 1"), T(u"125 1 126 1 127 1 128 0 50 1"),
            T(u"129 1 130 1 131 1 132 0 50 1"), B(1), Z(1), B(1), Z(1), H(1), R(40.0f), Z(16), T(u"JS14"), Z(16),
            T(u"H14"), Z(12), R(1.875f), Z(20)
        });
    style(u"Неуказанная шероховатость", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {
            B(1), Z(1)
        });
    style(u"Текстовая метка", {{{true, 5.0f, 5.0f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}, {false, 3.5f, 3.5f, 1.0f, 7.0f, 0x419}}}, u"GOST type A", 8, false, {
            W(1), B(42), Z(1), B(255), Z(2), B(255), Z(2), B(255), Z(2), H(1), R(2.0f), B(4), Z(1)
        });
    return table;
}

// Each style: the name, 1.0 (a double), the four levels (a flag, four floats, the language), the font, an empty
// word, the kind, 25 empty bytes, the flag, then the extension.
bool encodeKompasTextStyles(const KompasTextStyleTable& table, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    Writer w;
    for (const auto& f : table.header) w.field(f);
    for (const auto& s : table.styles) {
        if (s.name.isEmpty() || s.font.isEmpty()) {
            error = QObject::tr("Текстовый стиль КОМПАС без имени или шрифта.");
            return false;
        }
        w.string(s.name);
        const double one = 1.0;
        quint64 bits;
        std::memcpy(&bits, &one, sizeof bits);
        w.number(bits, 8);
        for (const auto& l : s.levels) {
            w.number(l.first ? 1 : 0, 1);
            w.real(l.height);
            w.real(l.width);
            w.real(l.factor);
            w.real(l.step);
            w.number(l.language, 4);
        }
        w.string(s.font);
        w.number(0, 4);
        w.number(s.kind, 4);
        w.bytes.append(25, '\0');
        w.number(s.flag ? 1 : 0, 1);
        for (const auto& f : s.extension) w.field(f);
    }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasTextStyles(const QByteArray& bytes, KompasTextStyleTable& table, QString& error) {
    table = {};
    error.clear();
    const KompasTextStyleTable layout = kompasDefaultTextStyles();
    try {
        Reader r{bytes};
        for (const auto& f : layout.header) table.header.push_back(r.field(f));
        for (const auto& model : layout.styles) {
            KompasTextStyle s;
            s.name = r.string();
            const quint64 bits = r.number(8);
            double one;
            std::memcpy(&one, &bits, sizeof one);
            if (one != 1.0) throw std::runtime_error("style");
            for (auto& l : s.levels) {
                const auto first = r.number(1);
                if (first > 1) throw std::runtime_error("level");
                l.first = first != 0;
                l.height = r.real();
                l.width = r.real();
                l.factor = r.real();
                l.step = r.real();
                l.language = quint32(r.number(4));
            }
            s.font = r.string();
            if (r.number(4) != 0) throw std::runtime_error("style");
            s.kind = quint32(r.number(4));
            for (int i = 0; i < 25; ++i)
                if (r.number(1)) throw std::runtime_error("style");
            const auto flag = r.number(1);
            if (flag > 1 || s.name.isEmpty() || s.font.isEmpty()) throw std::runtime_error("style");
            s.flag = flag != 0;
            for (const auto& f : model.extension) s.extension.push_back(r.field(f));
            table.styles.push_back(std::move(s));
        }
        if (r.at != bytes.size()) throw std::runtime_error("trailing");
        return true;
    } catch (const std::exception&) {
        table = {};
        error = QObject::tr("Таблица текстовых стилей КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

} // namespace cadnext::gui
