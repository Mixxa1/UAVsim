#pragma once

#include <string>

#include "cadnext/Document.hpp"

namespace cadnext {

// Undo/redo foundation (CADNext 0.3). Commands capture enough state to
// re-apply or roll back one document mutation. Coverage is intentionally
// minimal at this stage; more commands arrive with the OCCT-backed
// operations in later stages.
class Command {
public:
    virtual ~Command() = default;
    virtual void undo(Document& document) = 0;
    virtual void redo(Document& document) = 0;
    virtual std::string name() const = 0;
};

// Renames an object. If the object no longer exists (e.g. it was deleted
// after this command was recorded), undo/redo become safe no-ops.
class RenameObjectCommand : public Command {
public:
    RenameObjectCommand(std::string objectId, std::string oldName, std::string newName);

    void undo(Document& document) override;
    void redo(Document& document) override;
    std::string name() const override;

private:
    std::string objectId_;
    std::string oldName_;
    std::string newName_;
};

// Adds a sketch entity. Undo removes it again; both directions are safe
// no-ops when the sketch (or entity) is gone.
class AddSketchEntityCommand : public Command {
public:
    AddSketchEntityCommand(std::string sketchId, SketchEntity entity);

    void undo(Document& document) override;
    void redo(Document& document) override;
    std::string name() const override;

private:
    std::string sketchId_;
    SketchEntity entity_;
};

// Renames a sketch entity; safe no-op when the sketch/entity is gone.
class RenameSketchEntityCommand : public Command {
public:
    RenameSketchEntityCommand(std::string sketchId, std::string entityId, std::string oldName,
                              std::string newName);

    void undo(Document& document) override;
    void redo(Document& document) override;
    std::string name() const override;

private:
    std::string sketchId_;
    std::string entityId_;
    std::string oldName_;
    std::string newName_;
};

} // namespace cadnext
