#pragma once

#include <memory>
#include <vector>

#include "cadnext/Command.hpp"

namespace cadnext {

// Linear undo/redo stack. push() executes the command (redo) and clears
// the redo history, mirroring the usual editor convention.
class CommandStack {
public:
    void push(std::unique_ptr<Command> command, Document& document);

    bool canUndo() const;
    bool canRedo() const;

    void undo(Document& document);
    void redo(Document& document);

    void clear();
    size_t undoCount() const;

private:
    std::vector<std::unique_ptr<Command>> undoStack_;
    std::vector<std::unique_ptr<Command>> redoStack_;
};

} // namespace cadnext
