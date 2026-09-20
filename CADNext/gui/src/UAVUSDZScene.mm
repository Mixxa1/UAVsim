#include "cadnext/gui/UAVUSDZScene.hpp"
#import <SceneKit/SceneKit.h>
#import <AppKit/AppKit.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoNormal.h>
#include <Inventor/nodes/SoNormalBinding.h>
#include <Inventor/nodes/SoTexture2.h>
#include <Inventor/nodes/SoTextureCoordinate2.h>
#include <Inventor/nodes/SoShapeHints.h>
#include <cmath>
#include <cstring>
#include <vector>

namespace cadnext::gui {
namespace {
double component(SCNGeometrySource* source, NSInteger vertex, NSInteger axis) {
    const auto offset=source.dataOffset+vertex*source.dataStride+axis*source.bytesPerComponent;
    if(offset<0 || offset+source.bytesPerComponent>source.data.length)return 0;
    const auto* p=static_cast<const unsigned char*>(source.data.bytes)+offset;
    if(source.floatComponents && source.bytesPerComponent==4){float v;std::memcpy(&v,p,4);return v;}
    if(source.floatComponents && source.bytesPerComponent==8){double v;std::memcpy(&v,p,8);return v;}
    return 0;
}
uint32_t index(SCNGeometryElement* element, NSUInteger i, NSUInteger channel=0) {
    uint32_t v=0;const auto bytes=element.bytesPerIndex;
    const auto channels=std::max<NSUInteger>(1,element.indicesChannelCount);
    const auto indexCount=static_cast<NSUInteger>(element.primitiveCount)*3;
    const auto slot=element.hasInterleavedIndicesChannels ? i*channels+channel : channel*indexCount+i;
    if(bytes<=4 && (slot+1)*bytes<=element.data.length)std::memcpy(&v,static_cast<const char*>(element.data.bytes)+slot*bytes,bytes);
    return v;
}
void addNode(SCNNode* node, SoSeparator* root, size_t& triangles) {
    [node removeAllAnimations];
    SCNGeometry* geometry=node.geometry;
    SCNGeometrySource* vertices=[geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
    SCNGeometrySource* normals=[geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticNormal].firstObject;
    SCNGeometrySource* uv=[geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticTexcoord].firstObject;
    if(vertices && vertices.vectorCount>0) {
        NSUInteger totalCorners=0;
        for(SCNGeometryElement* item in geometry.geometryElements)
            if(item.primitiveType==SCNGeometryPrimitiveTypeTriangles) totalCorners+=item.primitiveCount*3;
        NSUInteger faceCornerOffset=0;
        for(NSUInteger e=0;e<geometry.geometryElements.count;++e) {
            SCNGeometryElement* element=geometry.geometryElements[e];
            if(element.primitiveType!=SCNGeometryPrimitiveTypeTriangles)continue;
            auto* part=new SoSeparator;
            if(node.name.length)part->setName(node.name.UTF8String);
            auto* material=new SoMaterial;
            SCNMaterial* source=geometry.materials.count ? geometry.materials[e%geometry.materials.count] : nil;
            id contents=source.diffuse.contents;
            NSColor* color=[contents isKindOfClass:NSColor.class] ? [contents colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace] : nil;
            if(color)material->diffuseColor.setValue(color.redComponent,color.greenComponent,color.blueComponent);
            else if([contents isKindOfClass:NSImage.class]) material->diffuseColor.setValue(1,1,1);
            else material->diffuseColor.setValue(.72,.75,.78);
            material->transparency.setValue(1.0-(source ? source.transparency : 1.0)*(color ? color.alphaComponent : 1.0));
            part->addChild(material);
            if(uv && [contents isKindOfClass:NSImage.class]) {
                NSBitmapImageRep* bitmap=[NSBitmapImageRep imageRepWithData:[contents TIFFRepresentation]];
                if(bitmap && bitmap.pixelsWide>0 && bitmap.pixelsHigh>0 && bitmap.pixelsWide<=4096 && bitmap.pixelsHigh<=4096) {
                    std::vector<unsigned char> pixels(bitmap.pixelsWide*bitmap.pixelsHigh*4);
                    for(NSInteger y=0;y<bitmap.pixelsHigh;++y)for(NSInteger x=0;x<bitmap.pixelsWide;++x) {
                        NSColor* c=[[bitmap colorAtX:x y:bitmap.pixelsHigh-1-y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                        const auto at=(y*bitmap.pixelsWide+x)*4;
                        pixels[at]=c.redComponent*255;pixels[at+1]=c.greenComponent*255;pixels[at+2]=c.blueComponent*255;pixels[at+3]=c.alphaComponent*255;
                    }
                    auto* texture=new SoTexture2;texture->image.setValue(SbVec2s(bitmap.pixelsWide,bitmap.pixelsHigh),4,pixels.data());part->addChild(texture);
                }
            }
            // USD commonly stores blade normals and UVs as `faceVarying`: one value for
            // every triangle corner rather than one value for every position. Coin can
            // represent this with separate indices, but SceneKit does not expose the USD
            // interpolation token. Expanding triangle corners is unambiguous and preserves
            // hard edges and texture seams instead of letting Coin invent faceted normals.
            const auto cornerCount=element.primitiveCount*3;
            auto sourceIndex=[&](SCNGeometrySource* source, NSUInteger corner, uint32_t vertex) {
                if(!source)return NSNotFound;
                if(source.vectorCount==vertices.vectorCount)return static_cast<NSInteger>(vertex);
                if(source.vectorCount==totalCorners)return static_cast<NSInteger>(faceCornerOffset+corner);
                if(source.vectorCount==totalCorners/3)return static_cast<NSInteger>(faceCornerOffset/3+corner/3);
                if(source.vectorCount==1)return NSInteger{0};
                return NSNotFound;
            };
            auto* coordinates=new SoCoordinate3;coordinates->point.setNum(cornerCount);
            SoNormal* coinNormals=nullptr;
            SoNormalBinding* normalBinding=nullptr;
            const bool normalsSupported=normals &&
                (normals.vectorCount==vertices.vectorCount || normals.vectorCount==totalCorners ||
                 normals.vectorCount==totalCorners/3 || normals.vectorCount==1);
            if(normalsSupported) {
                coinNormals=new SoNormal; coinNormals->vector.setNum(cornerCount);
                normalBinding=new SoNormalBinding; normalBinding->value=SoNormalBinding::PER_VERTEX;
            }
            SoTextureCoordinate2* textureCoordinates=nullptr;
            const bool uvSupported=uv &&
                (uv.vectorCount==vertices.vectorCount || uv.vectorCount==totalCorners ||
                 uv.vectorCount==totalCorners/3 || uv.vectorCount==1);
            if(uvSupported) { textureCoordinates=new SoTextureCoordinate2;textureCoordinates->point.setNum(cornerCount); }
            auto* faces=new SoIndexedFaceSet;
            int at=0;
            for(NSInteger t=0;t<element.primitiveCount;++t) {
                uint32_t a=index(element,3*t),b=index(element,3*t+1),c=index(element,3*t+2);
                if(a>=vertices.vectorCount||b>=vertices.vectorCount||c>=vertices.vectorCount)continue;
                const uint32_t sourceVertices[3]={a,b,c};
                SCNVector3 positions[3];
                for(int corner=0;corner<3;++corner) {
                    const auto vertex=sourceVertices[corner];
                    positions[corner]=[node convertPosition:SCNVector3Make(component(vertices,vertex,0),component(vertices,vertex,1),component(vertices,vertex,2)) toNode:nil];
                }
                SbVec3f faceNormal(
                    (positions[1].y-positions[0].y)*(positions[2].z-positions[0].z)-(positions[1].z-positions[0].z)*(positions[2].y-positions[0].y),
                    (positions[1].z-positions[0].z)*(positions[2].x-positions[0].x)-(positions[1].x-positions[0].x)*(positions[2].z-positions[0].z),
                    (positions[1].x-positions[0].x)*(positions[2].y-positions[0].y)-(positions[1].y-positions[0].y)*(positions[2].x-positions[0].x));
                if(faceNormal.length()>1e-12f)faceNormal.normalize();else faceNormal.setValue(0,1,0);
                for(int corner=0;corner<3;++corner) {
                    const auto expanded=3*t+corner;
                    const auto vertex=sourceVertices[corner];
                    const SCNVector3 p=positions[corner];
                    coordinates->point.set1Value(expanded,p.x,p.y,p.z);
                    const auto attributeIndex=index(element,3*t+corner,1);
                    const auto normalAt=sourceIndex(normals,attributeIndex,vertex);
                    if(coinNormals) {
                        if(normalAt!=NSNotFound) {
                            SCNVector3 n=[node convertVector:SCNVector3Make(component(normals,normalAt,0),component(normals,normalAt,1),component(normals,normalAt,2)) toNode:nil];
                            const double length=std::sqrt(n.x*n.x+n.y*n.y+n.z*n.z);
                            if(length>1e-12){n.x/=length;n.y/=length;n.z/=length;coinNormals->vector.set1Value(expanded,n.x,n.y,n.z);}
                            else coinNormals->vector.set1Value(expanded,faceNormal);
                        } else coinNormals->vector.set1Value(expanded,faceNormal);
                    }
                    const auto uvAt=sourceIndex(uv,attributeIndex,vertex);
                    if(textureCoordinates && uvAt!=NSNotFound)
                        textureCoordinates->point.set1Value(expanded,component(uv,uvAt,0),component(uv,uvAt,1));
                    faces->coordIndex.set1Value(at++,expanded);
                }
                faces->coordIndex.set1Value(at++,-1);++triangles;
            }
            part->addChild(coordinates);
            if(coinNormals) { part->addChild(coinNormals);part->addChild(normalBinding); }
            if(textureCoordinates)part->addChild(textureCoordinates);
            part->addChild(faces);root->addChild(part);
            faceCornerOffset+=cornerCount;
        }
    }
    for(SCNNode* child in node.childNodes)addNode(child,root,triangles);
}
}
SoSeparator* loadUAVUSDZ(const std::string& path, std::string& error) {
    @autoreleasepool {
        NSError* failure=nil;
        SCNScene* scene=[SCNScene sceneWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]] options:@{SCNSceneSourceAnimationImportPolicyKey: SCNSceneSourceAnimationImportPolicyDoNotPlay, SCNSceneSourceCheckConsistencyKey: @NO} error:&failure];
        if(!scene){error=failure.localizedDescription.UTF8String ?: "USDZ import failed";return nullptr;}
        // Match UAVModelAssetLibrary.template: neutral airframe and servo pose.
        NSString* assetPath=[NSString stringWithUTF8String:path.c_str()];
        NSData* manifestData=[NSData dataWithContentsOfFile:[[assetPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"manifest.json"]];
        NSDictionary* manifest=manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
        NSString* assetID=[[assetPath lastPathComponent] stringByDeletingPathExtension];
        for(NSDictionary* entry in manifest[@"models"]) if([entry[@"id"] isEqualToString:assetID]) {
            NSDictionary* transition=[entry[@"transition"] isKindOfClass:NSDictionary.class] ? entry[@"transition"] : nil;
            for(NSDictionary* pivot in transition[@"pivots"]) [scene.rootNode childNodeWithName:pivot[@"name"] recursively:YES].eulerAngles=SCNVector3Zero;
            if([transition[@"body_node"] isKindOfClass:NSString.class]) [scene.rootNode childNodeWithName:transition[@"body_node"] recursively:YES].eulerAngles=SCNVector3Zero;
        }
        auto* result=new SoSeparator;result->ref();
        auto* hints=new SoShapeHints;hints->vertexOrdering=SoShapeHints::UNKNOWN_ORDERING;hints->shapeType=SoShapeHints::UNKNOWN_SHAPE_TYPE;hints->creaseAngle=.6;result->addChild(hints);
        size_t triangles=0;addNode(scene.rootNode,result,triangles);
        if(!triangles){error="USDZ has no triangle geometry";result->unref();return nullptr;}
        result->unrefNoDelete();return result;
    }
}
}
