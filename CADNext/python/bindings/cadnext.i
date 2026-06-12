%module cadnext

%{
#include "cadnext/Document.hpp"
#include "cadnext/Object.hpp"
#include "cadnext/Feature.hpp"
#include "cadnext/Material.hpp"
#include "cadnext/Transform.hpp"
#include "cadnext/AttachmentPoint.hpp"
#include "cadnext/bridge/UAVSimBridge.hpp"
%}

%include "std_string.i"
%include "std_vector.i"

%include "cadnext/Units.hpp"
%include "cadnext/Transform.hpp"
%include "cadnext/Material.hpp"
%include "cadnext/AttachmentPoint.hpp"
%include "cadnext/Feature.hpp"
%include "cadnext/Object.hpp"
%include "cadnext/Document.hpp"
%include "cadnext/bridge/UAVSimBridge.hpp"
