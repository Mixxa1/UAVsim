#include <cadnext/gui/UAVUSDZScene.hpp>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <Inventor/SoDB.h>
#include <Inventor/actions/SoGetBoundingBoxAction.h>
#include <Inventor/actions/SoGetPrimitiveCountAction.h>
#include <Inventor/actions/SoSearchAction.h>
#include <Inventor/nodes/SoNormal.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoTextureCoordinate2.h>
#include <Inventor/nodes/SoSeparator.h>
#include <cmath>
#include <algorithm>
#include <cstdio>
int main(int argc,char** argv){
 QCoreApplication app(argc,argv);SoDB::init();if(argc!=2)return 64;
 QDir root(QString::fromUtf8(argv[1]));QFile f(root.filePath("manifest.json"));if(!f.open(QIODevice::ReadOnly))return 1;
 int failures=0,count=0;
 for(const auto& v:QJsonDocument::fromJson(f.readAll()).object()["models"].toArray()){
  auto m=v.toObject();std::string error;auto* scene=cadnext::gui::loadUAVUSDZ(root.filePath(QFileInfo(m["file"].toString()).fileName()).toStdString(),error);
  if(!scene){fprintf(stderr,"%s: %s\n",qPrintable(m["id"].toString()),error.c_str());++failures;continue;}
  scene->ref();SoGetBoundingBoxAction bounds(SbViewportRegion(640,480));bounds.apply(scene);auto box=bounds.getBoundingBox();SoGetPrimitiveCountAction primitives;primitives.apply(scene);
  SoSearchAction normalSearch;normalSearch.setType(SoNormal::getClassTypeId());normalSearch.setInterest(SoSearchAction::FIRST);normalSearch.apply(scene);
  bool valid=!box.isEmpty()&&primitives.getTriangleCount()>0&&normalSearch.getPath()!=nullptr;auto low=m["bounds_min_m"].toArray(),high=m["bounds_max_m"].toArray();
  if(m["id"].toString()=="dji-flycart-30") {
   SoSearchAction bladeSearch;bladeSearch.setName(SbName("Blade_01"));bladeSearch.setInterest(SoSearchAction::FIRST);bladeSearch.apply(scene);
   bool bladeAttributes=false;
   if(auto* bladePath=bladeSearch.getPath()) {
    SoSearchAction n;n.setType(SoNormal::getClassTypeId());n.setInterest(SoSearchAction::FIRST);n.apply(bladePath->getTail());
    SoSearchAction c;c.setType(SoCoordinate3::getClassTypeId());c.setInterest(SoSearchAction::FIRST);c.apply(bladePath->getTail());
    SoSearchAction uv;uv.setType(SoTextureCoordinate2::getClassTypeId());uv.setInterest(SoSearchAction::FIRST);uv.apply(bladePath->getTail());
    if(n.getPath()&&c.getPath()&&uv.getPath()) {
     const auto* normals=static_cast<const SoNormal*>(n.getPath()->getTail());const auto* coordinates=static_cast<const SoCoordinate3*>(c.getPath()->getTail());const auto* texture=static_cast<const SoTextureCoordinate2*>(uv.getPath()->getTail());
     bladeAttributes=normals->vector.getNum()==coordinates->point.getNum()&&texture->point.getNum()==coordinates->point.getNum();
     float minimum=1e9f;int zeroes=0;for(int i=0;i<normals->vector.getNum();++i){minimum=std::min(minimum,normals->vector[i].length());zeroes+=normals->vector[i].length()<.01f;bladeAttributes &= normals->vector[i].length()>.99f;}
     if(!bladeAttributes)printf("Blade_01 attributes: coordinates %d, normals %d, UVs %d, shortest normal %f, zero normals %d, points (%f,%f,%f) (%f,%f,%f) (%f,%f,%f), normals (%f,%f,%f) (%f,%f,%f)\n",coordinates->point.getNum(),normals->vector.getNum(),texture->point.getNum(),minimum,zeroes,coordinates->point[0][0],coordinates->point[0][1],coordinates->point[0][2],coordinates->point[1][0],coordinates->point[1][1],coordinates->point[1][2],coordinates->point[2][0],coordinates->point[2][1],coordinates->point[2][2],normals->vector[0][0],normals->vector[0][1],normals->vector[0][2],normals->vector[1][0],normals->vector[1][1],normals->vector[1][2]);
    }
    else printf("Blade_01 nodes: normal %s, coordinates %s, UV %s\n",n.getPath()?"yes":"no",c.getPath()?"yes":"no",uv.getPath()?"yes":"no");
   }
   valid &= bladeAttributes;
   printf("%s dji-flycart-30 blade face-varying normals and UVs preserved\n",bladeAttributes?"PASS":"FAIL");
  }
  // Manifest bounds include the authored rotor envelope; a static blade may occupy less.
  for(int a=0;a<3;++a)valid &= std::isfinite(box.getMin()[a])&&box.getMin()[a]>=low[a].toDouble()-.02&&box.getMax()[a]<=high[a].toDouble()+.02&&(box.getMax()[a]-box.getMin()[a])>=.8*(high[a].toDouble()-low[a].toDouble());
  printf("%s %s: %d triangles, authored normals %s\n",valid?"PASS":"FAIL",qPrintable(m["id"].toString()),primitives.getTriangleCount(),normalSearch.getPath()?"yes":"no");if(!valid){++failures;for(int a=0;a<3;++a)printf("axis %d: actual %f %f, manifest %f %f\n",a,box.getMin()[a],box.getMax()[a],low[a].toDouble(),high[a].toDouble());}
  scene->unref();++count;
 }
 printf("%d USDZ assets checked, %d failures\n",count,failures);return failures?1:0;
}
