#include "cadnext/Command.hpp"

#include <utility>

namespace cadnext {

RenameObjectCommand::RenameObjectCommand(std::string objectId, std::string oldName,
                                         std::string newName)
    : objectId_(std::move(objectId)),
      oldName_(std::move(oldName)),
      newName_(std::move(newName)) {}

void RenameObjectCommand::undo(Document& document) {
    if (Object* object = document.mutableObjectById(objectId_)) {
        object->name = oldName_;
    }
}

void RenameObjectCommand::redo(Document& document) {
    if (Object* object = document.mutableObjectById(objectId_)) {
        object->name = newName_;
    }
}

std::string RenameObjectCommand::name() const {
    return "Rename " + oldName_ + " to " + newName_;
}

AddSketchEntityCommand::AddSketchEntityCommand(std::string sketchId, SketchEntity entity)
    : sketchId_(std::move(sketchId)), entity_(std::move(entity)) {}

void AddSketchEntityCommand::undo(Document& document) {
    if (Sketch* sketch = document.mutableSketchById(sketchId_)) {
        removeSketchEntity(*sketch, entity_.id);
    }
}

void AddSketchEntityCommand::redo(Document& document) {
    Sketch* sketch = document.mutableSketchById(sketchId_);
    if (sketch && !findSketchEntity(*sketch, entity_.id)) {
        sketch->entities.push_back(entity_);
    }
}

std::string AddSketchEntityCommand::name() const {
    return "Add " + entity_.name;
}

RenameSketchEntityCommand::RenameSketchEntityCommand(std::string sketchId, std::string entityId,
                                                     std::string oldName, std::string newName)
    : sketchId_(std::move(sketchId)),
      entityId_(std::move(entityId)),
      oldName_(std::move(oldName)),
      newName_(std::move(newName)) {}

void RenameSketchEntityCommand::undo(Document& document) {
    if (Sketch* sketch = document.mutableSketchById(sketchId_)) {
        if (SketchEntity* entity = findSketchEntity(*sketch, entityId_)) {
            entity->name = oldName_;
        }
    }
}

void RenameSketchEntityCommand::redo(Document& document) {
    if (Sketch* sketch = document.mutableSketchById(sketchId_)) {
        if (SketchEntity* entity = findSketchEntity(*sketch, entityId_)) {
            entity->name = newName_;
        }
    }
}

std::string RenameSketchEntityCommand::name() const {
    return "Rename " + oldName_ + " to " + newName_;
}

} // namespace cadnext
