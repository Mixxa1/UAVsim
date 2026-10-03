#pragma once

#include <cstddef>
#include <span>

// The tables NativeSolidWorksPartBlueprint.cpp holds (generated); read by NativeSolidWorksPart.cpp.
namespace cadnext::gui::solidworks_blueprint {

// A piece of a stream:
//   'C' a new MFC class (text: its name, number: its schema)   'R' a reference to a class named before
//   'S' a string, as is                                        'V' a string slot (text: the slot)
//   'B' native bytes (text: hex)
//   'T' a Unix time, 32 bits (text: which)                     'F' / 'G' a FILETIME, low or high half first
//   'D' a double (text: the formula of the body's box)
//   'U' 32 bits, 'Q' 64 bits, 'Y' a byte (text: "name=default in hex")
//   'L' literal text of a text stream                          'X' a slot of one, XML-escaped
struct Piece {
    char kind;
    unsigned short number;
    const char* text;
};

enum class StreamKind { Mfc, Binary, Text };

struct Stream {
    const char* name;
    StreamKind kind;
    const Piece* pieces;
    std::size_t count;
};

struct Default {
    const char* slot;
    const char* text;
};

struct Entry {
    const char* name;
    unsigned stamp;
};

std::span<const Stream> streams();
std::span<const Default> defaults();
std::span<const Entry> entries();     // the package's streams in order, with their stamps
const char* partitionGuid();          // hex of the 16 bytes that open a Parasolid chunk
unsigned char keyWordsPrefix();       // the byte before swXmlContents/KeyWords' text

} // namespace cadnext::gui::solidworks_blueprint
