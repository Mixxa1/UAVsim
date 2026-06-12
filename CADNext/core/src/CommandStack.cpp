#include "cadnext/CommandStack.hpp"

#include <utility>

namespace cadnext {

void CommandStack::push(std::unique_ptr<Command> command, Document& document) {
    if (!command) {
        return;
    }
    command->redo(document);
    undoStack_.push_back(std::move(command));
    redoStack_.clear();
}

bool CommandStack::canUndo() const {
    return !undoStack_.empty();
}

bool CommandStack::canRedo() const {
    return !redoStack_.empty();
}

void CommandStack::undo(Document& document) {
    if (undoStack_.empty()) {
        return;
    }
    std::unique_ptr<Command> command = std::move(undoStack_.back());
    undoStack_.pop_back();
    command->undo(document);
    redoStack_.push_back(std::move(command));
}

void CommandStack::redo(Document& document) {
    if (redoStack_.empty()) {
        return;
    }
    std::unique_ptr<Command> command = std::move(redoStack_.back());
    redoStack_.pop_back();
    command->redo(document);
    undoStack_.push_back(std::move(command));
}

void CommandStack::clear() {
    undoStack_.clear();
    redoStack_.clear();
}

size_t CommandStack::undoCount() const {
    return undoStack_.size();
}

} // namespace cadnext
