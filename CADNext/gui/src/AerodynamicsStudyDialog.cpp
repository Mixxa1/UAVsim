#include <cadnext/gui/AerodynamicsStudyDialog.hpp>
#include <cadnext/cfd/AerodynamicStudy.hpp>
#include <cadnext/cfd/FlowSection.hpp>
#include "FlowResultView.hpp"
#include "ViewerSnapshot.hpp"
#include <QApplication>
#include <fstream>
#include <QComboBox>
#include <QDoubleSpinBox>
#include <QGroupBox>
#include <QFileInfo>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QFormLayout>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QProcess>
#include <QProgressBar>
#include <QPushButton>
#include <QRegularExpression>
#include <QSplitter>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <QUuid>
#include <QVBoxLayout>
#include <QCloseEvent>
#include <QFrame>
#include <QScrollArea>
#include <QSpinBox>
#include <QCheckBox>
#include <QElapsedTimer>
#include <QTabWidget>
#include <QTableWidget>
#include <QHeaderView>
#include <QPainter>
#include <map>
#include <Inventor/nodes/SoSwitch.h>
#include <Inventor/nodes/SoPointSet.h>
#include <Inventor/Qt/viewers/SoQtPlaneViewer.h>
#include <Inventor/SbRotation.h>
#include <Inventor/actions/SoGLRenderAction.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoCamera.h>
#include <Inventor/nodes/SoOrthographicCamera.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoLineSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoMaterialBinding.h>
#include <Inventor/nodes/SoDrawStyle.h>
#include <Inventor/nodes/SoLightModel.h>
#include <cmath>
#include <algorithm>
#include <array>
#include <limits>

namespace cadnext::gui {
namespace {
class CoefficientPlot final : public QWidget {
public:
    QJsonArray samples;
    QString axis="alphaDeg",coefficient="cl";
    explicit CoefficientPlot(QWidget* parent=nullptr):QWidget(parent){setMinimumHeight(250);}
    void paintEvent(QPaintEvent*) override {
        QPainter p(this);p.setRenderHint(QPainter::Antialiasing);p.fillRect(rect(),palette().base());p.setPen(palette().text().color());
        const QRectF plot(65,35,std::max(width()-105,1),std::max(height()-110,1));
        if(samples.isEmpty()){p.drawText(rect(),Qt::AlignCenter,tr("Графики появятся после успешной проверки расчётных точек."));return;}
        std::map<double,std::vector<QPointF>> groups;double xmin=INFINITY,xmax=-INFINITY,ymin=INFINITY,ymax=-INFINITY;
        for(auto value:samples){auto s=value.toObject();if(!s[axis].isDouble()||!s[coefficient].isDouble())continue;double x=s[axis].toDouble(),y=s[coefficient].toDouble();if(!std::isfinite(x)||!std::isfinite(y))continue;groups[s[axis=="alphaDeg"?"betaDeg":"alphaDeg"].toDouble()].push_back({x,y});xmin=std::min(xmin,x);xmax=std::max(xmax,x);ymin=std::min(ymin,y);ymax=std::max(ymax,y);}
        if(!std::isfinite(xmin))return;if(xmax==xmin){xmin-=1;xmax+=1;}if(ymax==ymin){ymin-=.1;ymax+=.1;}
        double pad=(ymax-ymin)*.1;ymin-=pad;ymax+=pad;p.drawRect(plot);
        for(int i=0;i<=4;++i){double f=i/4.;p.drawText(QRectF(0,plot.bottom()-f*plot.height()-10,60,20),Qt::AlignRight,QString::number(ymin+f*(ymax-ymin),'g',4));p.drawText(QRectF(plot.left()+f*plot.width()-30,plot.bottom()+5,60,20),Qt::AlignCenter,QString::number(xmin+f*(xmax-xmin),'g',4));}
        p.drawText(QPointF(plot.left(),20),coefficient.toUpper());p.drawText(QRectF(plot.left(),plot.bottom()+28,plot.width(),20),Qt::AlignCenter,axis=="alphaDeg"?QStringLiteral("α, °"):QStringLiteral("β, °"));
        int group=0;for(auto& [angle,curve]:groups){std::sort(curve.begin(),curve.end(),[](auto a,auto b){return a.x()<b.x();});QColor color=QColor::fromHsv((group++*83+195)%360,180,220);p.setPen(QPen(color,2));QPointF previous;bool first=true;for(auto point:curve){QPointF q(plot.left()+(point.x()-xmin)/(xmax-xmin)*plot.width(),plot.bottom()-(point.y()-ymin)/(ymax-ymin)*plot.height());if(!first)p.drawLine(previous,q);p.drawEllipse(q,3,3);previous=q;first=false;}p.drawText(QPointF(plot.left()+((group-1)%5)*100,height()-8),QString("%1=%2°").arg(axis=="alphaDeg"?"β":"α").arg(angle));}
    }
};
class Study final : public QDialog {
    bridge::ConstructionDescriptor construction;
    QProcess process;
    QPlainTextEdit *settings, *log;
    QLineEdit *adapter, *solver, *alpha, *beta;
    QDoubleSpinBox *speed, *area, *spanBox, *chordBox;
    QComboBox* model;
    QComboBox* wallMode;
    QComboBox* transition;
    QDoubleSpinBox* turbulence;
    QLabel* wallPlan;
    QComboBox* preset=nullptr;
    QLabel* timeEstimate=nullptr;
    QLabel* status;
    QComboBox* points;
    QPushButton *run, *cancel;
    QProgressBar* progressBar;
    detail::FlowResultView* resultView=nullptr;
    QString directory;
    QString processBuffer;
    QJsonObject result;
    QString liveFieldSignature, pendingFieldSignature;
    QLabel* convergenceStatus;
    bool stopping = false;
    // A saved result is being shown: its settings are what was computed and no preset may rewrite them.
    bool showingSaved = false;
    bool provisionalField = false;
    int requestedPoints = 1;
    QStringList timeFrameSuffixes;
    QString currentFieldSuffix;
    int timeFrameIndex=0;
    CoefficientPlot* coefficientPlot;
    QTableWidget* coefficientTable;
    QPlainTextEdit* reportConditions;
    QTabWidget* resultTabs;
public:
    Study(bridge::ConstructionDescriptor value, QWidget* parent) : QDialog(parent), construction(std::move(value)) {
        setAttribute(Qt::WA_DeleteOnClose); setWindowTitle(tr("CFD — аэродинамические испытания")); resize(1200,820);
        auto* layout = new QVBoxLayout(this);
        auto* intro = new QLabel(tr("Виртуальная аэротруба: точная геометрия документа обдувается решателем SU2. Задайте условия слева и нажмите «Запустить обдув» — справа появится обтекание."));
        intro->setWordWrap(true); layout->addWidget(intro);
        auto* split = new QSplitter; layout->addWidget(split,1);
        auto* left = new QWidget; auto* column = new QVBoxLayout(left); auto* scroller=new QScrollArea;scroller->setWidgetResizable(true);scroller->setWidget(left);split->addWidget(scroller);scroller->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        // Numbered steps, each in its own box: what the user decides, in the order it matters.
        auto section=[column](const QString& title){auto* box=new QGroupBox(title);auto* f=new QFormLayout(box);f->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);column->addWidget(box);return f;};
        auto hint=[](const QString& text){auto* label=new QLabel(text);label->setWordWrap(true);label->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);label->setStyleSheet(QStringLiteral("color: #aeb7c4;"));return label;};
        auto* conditions=section(tr("1. Условия обдува"));
        auto* physics=section(tr("2. Модель течения"));
        auto* referenceForm=section(tr("3. Опорные размеры для коэффициентов"));
        auto* quality=section(tr("4. Точность и время"));
        auto* runForm=section(tr("5. Расчёт"));
        auto* extras=new QFormLayout;column->addLayout(extras);column->addStretch(1);
        auto* tools = new QGroupBox(tr("Инструменты"));
        tools->setCheckable(true); tools->setChecked(false);
        auto* toolsForm = new QFormLayout(tools);
        adapter = new QLineEdit(QStringLiteral(CADNEXT_SOURCE_DIR "/build-netgen/cfd/occt/cadnext_cfd"));
        solver = new QLineEdit(QStringLiteral(CADNEXT_SOURCE_DIR "/third_party/su2/install/bin/SU2_CFD"));
        toolsForm->addRow(tr("CFD-модуль"),adapter); toolsForm->addRow(tr("Решатель SU2"),solver);
        for(auto* child:tools->findChildren<QWidget*>(QString(),Qt::FindDirectChildrenOnly))child->hide();
        connect(tools,&QGroupBox::toggled,this,[tools](bool visible){for(auto* child:tools->findChildren<QWidget*>(QString(),Qt::FindDirectChildrenOnly))child->setVisible(visible);});
        cfd::AeroSettings initial; initial.model="urans_sst"; initial.wallTreatment="resolved";
        initial.threads=cfd::recommendedSolverThreads();
        const double span=std::max(0.01, construction.boundingBoxMax.x-construction.boundingBoxMin.x);
        const double chord=std::max(0.01, construction.boundingBoxMax.y-construction.boundingBoxMin.y);
        initial.reference.areaM2=span*chord; initial.reference.spanM=span; initial.reference.chordM=chord;
        // Surface step: about sixty cells along the chord, enough for the pressure distribution to
        // have a shape. The near-wall stack is not a guess — it is the layer the flow will actually
        // have at this speed (WallResolution.hpp), so the first run starts inside the right regime.
        initial.wallSizeM=chord/60; initial.farfieldSizeM=std::max(span,chord);
        initial.timeStepSeconds=chord/(20.0*60.0);initial.timeSteps=240;initial.innerIterations=30;initial.averagingSteps=80;
        initial.residualTarget=-3.5;initial.coefficientAbsoluteTolerance=.005;initial.coefficientRelativeTolerance=.03;
        initial.layerHeightsM=cfd::planWallLayers(cfd::WallTreatment::Resolved,initial.speedMps,chord,initial.densityKgM3,initial.viscosityPaS).heightsM;
        model=new QComboBox;
        model->addItem(tr("URANS SST — во времени"),QStringLiteral("urans_sst"));
        model->addItem(tr("RANS SST — среднее поле"),QStringLiteral("sst"));
        model->addItem(tr("Ламинарное (Навье—Стокс)"),QStringLiteral("laminar"));
        model->addItem(tr("Эйлер, без вязкости"),QStringLiteral("euler"));
        model->setCurrentIndex(0);
        initial.timeoutSeconds=cfd::defaultTimeoutSeconds(model->currentData().toString().toStdString());
        physics->addRow(tr("Модель"),model);
        wallMode=new QComboBox;
        wallMode->addItem(tr("Разрешённый слой, y⁺ ≈ 1"),QStringLiteral("resolved"));
        wallMode->addItem(tr("Пристен. функции, y⁺ 30…300"),QStringLiteral("functions"));
        physics->addRow(tr("Стенка"),wallMode);
        transition=new QComboBox;
        transition->addItem(tr("Нет, турбулентный от кромки"),QStringLiteral("none"));
        transition->addItem(tr("γ-Reθ, ламинарный участок"),QStringLiteral("lm"));
        physics->addRow(tr("Переход"),transition);
        turbulence=new QDoubleSpinBox;turbulence->setDecimals(2);turbulence->setRange(.01,20);turbulence->setSingleStep(.1);turbulence->setSuffix(QStringLiteral(" %"));
        turbulence->setValue(initial.turbulenceIntensity*100);
        physics->addRow(tr("Турбулентность потока Tu"),turbulence);
        physics->addRow(hint(tr("RANS — одно установившееся поле, быстро. URANS — течение во времени (срыв вихрей), в десятки раз дольше. Ламинарная — только для малых Re, Эйлер — без трения.")));
        physics->addRow(hint(tr("Переход γ-Reθ: слой начинается ламинарным и переходит там, где это предсказывает модель по Tu. При Re < 10⁶ это меняет сопротивление трения на десятки процентов. Tu: спокойная атмосфера 0.05–0.1 %, аэротруба 0.1–1 %, за винтом — несколько процентов. Нужна разрешённая стенка.")));
        auto spin=[&](QFormLayout* target,const QString& title,double value,int decimals){auto* box=new QDoubleSpinBox;box->setDecimals(decimals);box->setRange(.00001,100000);box->setValue(value);target->addRow(title,box);return box;};
        speed=spin(conditions,tr("Скорость потока, м/с"),20,1); speed->setMaximum(100);
        alpha=new QLineEdit("0"); beta=new QLineEdit("0");conditions->addRow(tr("Угол атаки α, °"),alpha);conditions->addRow(tr("Скольжение β, °"),beta);
        conditions->addRow(hint(tr("Несколько углов — через точку с запятой: −5; 0; 5; 10. Каждый угол — отдельный расчёт.")));
        area=spin(referenceForm,tr("Площадь, м²"),span*chord,4); spanBox=spin(referenceForm,tr("Размах, м"),span,4); chordBox=spin(referenceForm,tr("Хорда, м"),chord,4);
        auto* advanced=new QGroupBox(tr("Сетка и сходимость — дополнительные параметры JSON"));advanced->setCheckable(true);advanced->setChecked(false);auto* advancedLayout=new QVBoxLayout(advanced);
        settings = new QPlainTextEdit; settings->setMaximumHeight(180); settings->hide();
        connect(advanced,&QGroupBox::toggled,settings,&QWidget::setVisible);
        settings->setPlainText(QJsonDocument::fromJson(QByteArray::fromStdString(cfd::aeroSettingsJson(initial).serialize())).toJson(QJsonDocument::Indented));
        auto* meshGroup=new QGroupBox(tr("Сетка и точность"));meshGroup->setCheckable(true);meshGroup->setChecked(false);
        auto* meshLayout=new QVBoxLayout(meshGroup);auto* meshControls=new QWidget;auto* meshForm=new QFormLayout(meshControls);meshLayout->addWidget(meshControls);
        auto updateParameter=[this](const char* name,double value){auto json=QJsonDocument::fromJson(settings->toPlainText().toUtf8()).object();json[name]=value;settings->setPlainText(QJsonDocument(json).toJson(QJsonDocument::Indented));};
        auto meshNumber=[&](const QString& title,double value,double minimum,double maximum,int decimals){auto* box=new QDoubleSpinBox;box->setDecimals(decimals);box->setRange(minimum,maximum);box->setValue(value);meshForm->addRow(title,box);return box;};
        auto* wall=meshNumber(tr("Шаг у поверхности, мм"),initial.wallSizeM*1000,.001,100000,3);
        auto* far=meshNumber(tr("Шаг в дальнем поле, м"),initial.farfieldSizeM,.001,10000,3);
        auto* margin=meshNumber(tr("Удаление границы, габаритов"),initial.farfieldLengths,1,100,1);
        auto* first=meshNumber(tr("Первый слой, мм"),initial.layerHeightsM.front()*1000,.00001,1000,5);
        auto* layers=new QSpinBox;layers->setRange(1,80);layers->setValue(initial.layerHeightsM.size());meshForm->addRow(tr("Число пристеночных слоёв"),layers);
        auto* growth=meshNumber(tr("Рост толщины слоёв"),1.2,1,2,2);
        wallPlan=new QLabel; wallPlan->setWordWrap(true); wallPlan->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);
        auto* applyPlan=new QPushButton(tr("Подобрать пристеночную сетку под скорость"));
        meshForm->addRow(wallPlan); meshForm->addRow(applyPlan);
        auto currentTreatment=[this]{ return wallMode->currentData().toString()=="functions" ? cfd::WallTreatment::Functions : cfd::WallTreatment::Resolved; };
        auto describePlan=[this,first,currentTreatment]{
            const auto json=QJsonDocument::fromJson(settings->toPlainText().toUtf8()).object();
            const double density=json["densityKgM3"].toDouble(1.225), viscosity=json["viscosityPaS"].toDouble(1.7894e-5);
            const bool viscous=model->currentData().toString()!="euler";
            const bool turbulent=model->currentData().toString().endsWith("sst");
            wallMode->setEnabled(turbulent);
            // The transition model runs on top of SST and needs the laminar sublayer meshed.
            const bool transitionAllowed=turbulent&&currentTreatment()==cfd::WallTreatment::Resolved;
            if(!transitionAllowed)transition->setCurrentIndex(0);
            transition->setEnabled(transitionAllowed);turbulence->setEnabled(turbulent);
            if(!viscous){wallPlan->setText(tr("Эйлер: пристеночные слои не строятся."));return;}
            const auto plan=cfd::planWallLayers(currentTreatment(),speed->value(),chordBox->value(),density,viscosity);
            const double expected=cfd::yPlusForHeight(first->value()/1000,speed->value(),chordBox->value(),density,viscosity);
            wallPlan->setText(tr("Re = %1 по хорде. Для этого режима: первый слой %2 мм, %3 слоёв с ростом %4 до δ₉₉ = %5 мм.\nТекущий первый слой %6 мм → ожидаемый y⁺ ≈ %7 (%8 — оценка по пластине, точное значение измеряется по расчёту).")
                .arg(plan.reynolds,0,'g',3).arg(plan.firstHeightM*1000,0,'g',3).arg(plan.heightsM.size()).arg(plan.growth,0,'g',2).arg(plan.boundaryLayerM*1000,0,'g',3)
                .arg(first->value(),0,'g',3).arg(expected,0,'g',2)
                .arg(currentTreatment()==cfd::WallTreatment::Resolved?tr("нужен ≈ 1"):tr("нужен 30…300")));
        };
        connect(applyPlan,&QPushButton::clicked,this,[this,first,layers,growth,wall,currentTreatment,describePlan]{
            const auto json=QJsonDocument::fromJson(settings->toPlainText().toUtf8()).object();
            const auto plan=cfd::planWallLayers(currentTreatment(),speed->value(),chordBox->value(),json["densityKgM3"].toDouble(1.225),json["viscosityPaS"].toDouble(1.7894e-5));
            if(plan.heightsM.empty())return;
            wall->setValue(chordBox->value()/60*1000);
            growth->setValue(plan.growth); layers->setValue(static_cast<int>(plan.heightsM.size())); first->setValue(plan.firstHeightM*1000);
            describePlan();
        });
        for(auto* box:{speed,chordBox}) connect(box,qOverload<double>(&QDoubleSpinBox::valueChanged),this,describePlan);
        connect(first,qOverload<double>(&QDoubleSpinBox::valueChanged),this,describePlan);
        connect(model,&QComboBox::currentIndexChanged,this,describePlan);
        connect(wallMode,&QComboBox::currentIndexChanged,this,describePlan);
        QTimer::singleShot(0,this,describePlan);
        auto* iterations=new QSpinBox;iterations->setRange(initial.convergenceWindow,100000);iterations->setValue(initial.iterations);meshForm->addRow(tr("Предел итераций"),iterations);
        auto* timeStep=meshNumber(tr("URANS: физический шаг, мс"),initial.timeStepSeconds*1000,.0001,10000,4);
        auto* timeSteps=new QSpinBox;timeSteps->setRange(10,100000);timeSteps->setValue(initial.timeSteps);meshForm->addRow(tr("URANS: временных шагов"),timeSteps);
        auto* innerSteps=new QSpinBox;innerSteps->setRange(2,10000);innerSteps->setValue(initial.innerIterations);meshForm->addRow(tr("URANS: внутренних итераций"),innerSteps);
        auto* averageSteps=new QSpinBox;averageSteps->setRange(5,initial.timeSteps/2);averageSteps->setValue(initial.averagingSteps);meshForm->addRow(tr("URANS: шагов усреднения"),averageSteps);
        connect(wall,qOverload<double>(&QDoubleSpinBox::valueChanged),this,[updateParameter](double v){updateParameter("wallSizeM",v/1000);});
        connect(far,qOverload<double>(&QDoubleSpinBox::valueChanged),this,[updateParameter](double v){updateParameter("farfieldSizeM",v);});
        connect(margin,qOverload<double>(&QDoubleSpinBox::valueChanged),this,[updateParameter](double v){updateParameter("farfieldLengths",v);});
        connect(iterations,qOverload<int>(&QSpinBox::valueChanged),this,[updateParameter](int v){updateParameter("iterations",v);});
        connect(timeStep,qOverload<double>(&QDoubleSpinBox::valueChanged),this,[updateParameter](double v){updateParameter("timeStepSeconds",v/1000);});
        connect(timeSteps,qOverload<int>(&QSpinBox::valueChanged),this,[updateParameter,averageSteps](int v){averageSteps->setMaximum(std::max(5,v/2));updateParameter("timeSteps",v);});
        connect(innerSteps,qOverload<int>(&QSpinBox::valueChanged),this,[updateParameter](int v){updateParameter("innerIterations",v);});
        connect(averageSteps,qOverload<int>(&QSpinBox::valueChanged),this,[updateParameter](int v){updateParameter("averagingSteps",v);});
        auto updateLayers=[this,first,layers,growth]{QJsonArray heights;double height=first->value()/1000;for(int i=0;i<layers->value();++i){heights.append(height);height*=growth->value();}auto json=QJsonDocument::fromJson(settings->toPlainText().toUtf8()).object();json["layerHeightsM"]=heights;settings->setPlainText(QJsonDocument(json).toJson(QJsonDocument::Indented));};
        connect(first,qOverload<double>(&QDoubleSpinBox::valueChanged),this,updateLayers);connect(growth,qOverload<double>(&QDoubleSpinBox::valueChanged),this,updateLayers);connect(layers,qOverload<int>(&QSpinBox::valueChanged),this,updateLayers);
        auto* meshHelp=new QLabel(tr("Меньший шаг уточняет сетку и увеличивает время расчёта. Начальные слои не гарантируют достаточное разрешение у стенки. Для вывода о сопротивлении нужна проверка сгущением сетки."));meshHelp->setWordWrap(true);meshForm->addRow(meshHelp);
        meshControls->hide();connect(meshGroup,&QGroupBox::toggled,meshControls,&QWidget::setVisible);
        referenceForm->addRow(hint(tr("Начальные значения — габаритный прямоугольник модели. Для крыла укажите его площадь и среднюю хорду.")));
        advancedLayout->addWidget(settings);
        // Two honest presets instead of a page of numbers. Both keep the first cell at y⁺ ≈ 1; the
        // quick one has half the surface resolution, a nearer far field and fewer iterations.
        preset=new QComboBox;
        preset->addItem(tr("Быстрая оценка"),QStringLiteral("quick"));
        preset->addItem(tr("Точный расчёт"),QStringLiteral("precise"));
        quality->addRow(tr("Режим"),preset);
        timeEstimate=new QLabel;timeEstimate->setWordWrap(true);timeEstimate->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);quality->addRow(timeEstimate);
        quality->addRow(meshGroup);
        auto applyPreset=[this,wall,margin,iterations]{
            if(showingSaved)return;
            const bool quick=preset->currentData().toString()==QStringLiteral("quick");
            wall->setValue(chordBox->value()/(quick?30.0:60.0)*1000);margin->setValue(quick?6:10);iterations->setValue(quick?600:2000);
            if(quick&&model->currentData().toString()==QStringLiteral("urans_sst"))model->setCurrentIndex(model->findData(QStringLiteral("sst")));
            estimateTime();
        };
        connect(preset,&QComboBox::currentIndexChanged,this,applyPreset);
        connect(settings,&QPlainTextEdit::textChanged,this,[this]{estimateTime();});
        // The per-point time limit follows the model; a saved run keeps the limit it was computed with.
        connect(model,&QComboBox::currentIndexChanged,this,[this,updateParameter,previous=model->currentData().toString()]() mutable {
            const QString selected=model->currentData().toString();
            if(!showingSaved){
                const auto json=QJsonDocument::fromJson(settings->toPlainText().toUtf8()).object();
                const double limit=json["timeoutSeconds"].toDouble();
                const double moved=cfd::timeoutAfterModelChange(limit,previous.toStdString(),selected.toStdString());
                if(moved!=limit)updateParameter("timeoutSeconds",moved);
            }
            previous=selected;estimateTime();
        });
        for(auto* box:{speed,chordBox})connect(box,qOverload<double>(&QDoubleSpinBox::valueChanged),this,[this]{estimateTime();});
        connect(alpha,&QLineEdit::textChanged,this,[this]{estimateTime();});connect(beta,&QLineEdit::textChanged,this,[this]{estimateTime();});
        QTimer::singleShot(0,this,applyPreset);
        run=new QPushButton(tr("Запустить обдув")); cancel=new QPushButton(tr("Остановить")); cancel->setEnabled(false);
        auto* actions = new QWidget; auto* actionsLayout = new QHBoxLayout(actions); actionsLayout->setContentsMargins(0,0,0,0);
        run->setMinimumHeight(34);cancel->setMinimumHeight(34);
        actionsLayout->addWidget(run); actionsLayout->addWidget(cancel); runForm->addRow(actions);
        progressBar=new QProgressBar;progressBar->setRange(0,100);progressBar->setValue(0);progressBar->setTextVisible(true);runForm->addRow(progressBar);
        convergenceStatus=new QLabel(tr("Расчёт ещё не запущен."));convergenceStatus->setWordWrap(true);convergenceStatus->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);runForm->addRow(convergenceStatus);
        auto* open=new QPushButton(tr("Загрузить результат…")); auto* folder=new QPushButton(tr("Открыть папку"));
        auto* outputActions = new QWidget; auto* outputLayout = new QHBoxLayout(outputActions); outputLayout->setContentsMargins(0,0,0,0);
        outputLayout->addWidget(open); outputLayout->addWidget(folder); runForm->addRow(outputActions);
        auto* logGroup = new QGroupBox(tr("Журнал расчёта")); logGroup->setCheckable(true); logGroup->setChecked(false);
        auto* logLayout = new QVBoxLayout(logGroup);
        log=new QPlainTextEdit; log->setReadOnly(true);log->setMaximumBlockCount(2000); log->setMaximumHeight(130); logLayout->addWidget(log);
        log->hide();connect(logGroup,&QGroupBox::toggled,log,&QWidget::setVisible);
        extras->addRow(logGroup);extras->addRow(advanced);extras->addRow(tools);
        for(auto* group:{tools,meshGroup,advanced,logGroup}){group->setMaximumHeight(32);connect(group,&QGroupBox::toggled,this,[group](bool expanded){group->setMaximumHeight(expanded?QWIDGETSIZE_MAX:32);});}
        // Lists size to their longest item by default, which pushed the settings column wider than
        // its scroll area and cut every row on the right. Let them shrink with the column instead.
        for(auto* box:left->findChildren<QComboBox*>()){box->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);box->setMinimumContentsLength(10);}
        auto* tabs=new QTabWidget;resultTabs=tabs;split->addWidget(tabs);auto* right=new QWidget;auto* viewLayout=new QVBoxLayout(right);tabs->addTab(right,tr("Обдув и поля"));split->setSizes({450,750});
        auto* report=new QWidget;auto* reportLayout=new QVBoxLayout(report);tabs->addTab(report,tr("Отчёт и графики"));
        auto* plotControls=new QHBoxLayout;auto* plotAxis=new QComboBox;plotAxis->addItems({tr("По углу атаки α"),tr("По скольжению β")});auto* plotCoefficient=new QComboBox;plotCoefficient->addItems({"CL","CD","Cm","CY","Croll","Cyaw"});plotControls->addWidget(plotAxis);plotControls->addWidget(plotCoefficient);reportLayout->addLayout(plotControls);
        coefficientPlot=new CoefficientPlot;reportLayout->addWidget(coefficientPlot,1);
        connect(plotAxis,&QComboBox::currentIndexChanged,this,[this](int i){coefficientPlot->axis=i?"betaDeg":"alphaDeg";coefficientPlot->update();});
        connect(plotCoefficient,&QComboBox::currentIndexChanged,this,[this](int i){coefficientPlot->coefficient=QStringList{"cl","cd","cm","cy","cRoll","cYaw"}[i];coefficientPlot->update();});
        coefficientTable=new QTableWidget;coefficientTable->setColumnCount(10);coefficientTable->setHorizontalHeaderLabels({"α, °","β, °","CL","CD","Cm","CY","Croll","Cyaw",tr("Невязка"),tr("Итерации")});coefficientTable->setEditTriggers(QAbstractItemView::NoEditTriggers);coefficientTable->horizontalHeader()->setSectionResizeMode(QHeaderView::ResizeToContents);reportLayout->addWidget(coefficientTable,1);
        reportConditions=new QPlainTextEdit;reportConditions->setReadOnly(true);reportConditions->setMaximumHeight(180);reportLayout->addWidget(reportConditions);
        points=new QComboBox;
        points->addItem(tr("Поля появятся после первой записи решателя"));
        points->setEnabled(false);
        coefficientTable->setToolTip(tr("Двойной щелчок по строке — открыть поле этой точки."));
        connect(coefficientTable,&QTableWidget::cellDoubleClicked,this,[this](int row,int){if(row<points->count()){points->setCurrentIndex(row);resultTabs->setCurrentIndex(0);}});
        auto* pointRow=new QHBoxLayout;pointRow->addWidget(new QLabel(tr("Расчётная точка")));pointRow->addWidget(points,1);viewLayout->addLayout(pointRow);
        resultView=new detail::FlowResultView;viewLayout->addWidget(resultView,1);
        status=new QLabel(tr("Слева задайте условия и нажмите «Запустить обдув». Здесь появится обтекание тела."));status->setWordWrap(true);status->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);viewLayout->addWidget(status);
        preview();
        auto* liveTimer=new QTimer(this);liveTimer->setInterval(1500);
        connect(liveTimer,&QTimer::timeout,this,[this]{
            if(process.state()==QProcess::NotRunning)return;
            const QString folder=QDir(directory).filePath(points->currentData().toString());
            const auto frames=QDir(folder).entryList({"volume_*.csv"},QDir::Files,QDir::Name);
            if(!frames.isEmpty()){timeFrameSuffixes.clear();for(const auto& frame:frames)timeFrameSuffixes<<frame.mid(6,frame.size()-10);timeFrameIndex=timeFrameSuffixes.size()-1;currentFieldSuffix=timeFrameSuffixes.last();}
            const QFileInfo volume(folder+"/volume"+currentFieldSuffix+".csv"),surface(folder+"/surface"+currentFieldSuffix+".csv");
            const QString signature=QString("%1:%2:%3:%4").arg(volume.size()).arg(volume.lastModified().toMSecsSinceEpoch()).arg(surface.size()).arg(surface.lastModified().toMSecsSinceEpoch());
            // Wait for a stable pair of files; the full node-count check in fields()
            // additionally rejects a truncated SU2 write.
            if(volume.size()>1024&&surface.size()>256&&signature==pendingFieldSignature&&signature!=liveFieldSignature){fields();liveFieldSignature=signature;}
            pendingFieldSignature=signature;
            QFile history(folder+"/history.csv");
            if(history.open(QIODevice::ReadOnly)){
                auto parsed=cfd::parseSu2History(history.readAll().toStdString());
                if(parsed.isOk()&&!parsed.value().empty()){
                    const auto& h=parsed.value();double residual=-INFINITY;
                    for(const auto& name:h.columns)if(name.find("rms[")==0)residual=std::max(residual,h.last(name));
                    const bool unsteady=result["settings"].toObject()["model"].toString()==QStringLiteral("urans_sst");
                    convergenceStatus->setText((unsteady?tr("Физический шаг %1 из %2\nНаибольшая внутренняя невязка: %3; цель или падение ≥ 1,5 порядка\nМгновенные CL: %5 · CD: %6\nИтог — среднее по временному окну."):tr("Итерация %1 из %2\nНаибольшая невязка: %3; цель: %4\nCL: %5 · CD: %6\nЗначения предварительные до проверки сходимости."))
                        .arg(progressBar->value()).arg(progressBar->maximum()).arg(residual,0,'f',2).arg(result["settings"].toObject()["residualTarget"].toDouble(),0,'f',2).arg(h.last("CL"),0,'g',5).arg(h.last("CD"),0,'g',5));
                }
            }
        });liveTimer->start();
        connect(run,&QPushButton::clicked,this,[this]{start();});
        connect(cancel,&QPushButton::clicked,this,[this]{stopping=true; process.terminate(); cancel->setEnabled(false); QTimer::singleShot(4000,this,[this]{if(process.state()!=QProcess::NotRunning)process.kill();});});
        connect(folder,&QPushButton::clicked,this,[this]{if(!directory.isEmpty())QDesktopServices::openUrl(QUrl::fromLocalFile(directory));});
        connect(open,&QPushButton::clicked,this,[this]{if(process.state()!=QProcess::NotRunning)return;auto path=QFileDialog::getOpenFileName(this,tr("Результат CFD"),{},"result.json (*.json)"); if(!path.isEmpty())load(path);});
        connect(points,&QComboBox::currentIndexChanged,this,[this]{refreshFrames();fields();});
        process.setProcessChannelMode(QProcess::MergedChannels);
        connect(&process,&QProcess::readyReadStandardOutput,this,[this]{
            processBuffer+=QString::fromUtf8(process.readAllStandardOutput());
            static const QRegularExpression progressExpression(
                QStringLiteral("^progress\\s+(\\d+)\\s+(domain|mesh|solve|collected)\\s+(\\d+)\\s+(\\d+)$"));
            int newline=0;
            while((newline=processBuffer.indexOf('\n'))>=0) {
                const QString line=processBuffer.left(newline).trimmed();processBuffer.remove(0,newline+1);
                const auto match=progressExpression.match(line);
                if(!match.hasMatch()){if(!line.isEmpty())log->appendPlainText(line);continue;}
                const int point=match.captured(1).toInt(),iteration=match.captured(3).toInt(),total=match.captured(4).toInt();const auto stage=match.captured(2);
                if(stage=="domain"){progressBar->setRange(0,0);progressBar->setFormat(tr("Подготовка расчётной области…"));status->setText(tr("Точка %1 из %2: подготовка расчётной области.").arg(point).arg(requestedPoints));}
                else if(stage=="mesh"){progressBar->setRange(0,0);progressBar->setFormat(tr("Построение объёмной сетки…"));status->setText(tr("Точка %1 из %2: построение объёмной сетки.").arg(point).arg(requestedPoints));}
                else if(stage=="solve"){
                    const bool unsteady=result["settings"].toObject()["model"].toString()==QStringLiteral("urans_sst");
                    progressBar->setRange(0,std::max(total,1));progressBar->setValue(std::min(iteration,total));progressBar->setFormat(unsteady?tr("Физический шаг %v из %m — %p%"):tr("Итерация %v из %m — %p%"));
                    const QString relative=QStringLiteral("flow/point-%1").arg(point-1);
                    if(points->currentData().toString()!=relative){points->blockSignals(true);points->clear();points->addItem(tr("В РАСЧЁТЕ: точка %1 из %2").arg(point).arg(requestedPoints),relative);points->setCurrentIndex(0);points->blockSignals(false);liveFieldSignature.clear();pendingFieldSignature.clear();timeFrameSuffixes.clear();currentFieldSuffix.clear();preview();}
                    status->setText(unsteady?tr("Точка %1 из %2: URANS, физический шаг %3 из %4. Поле и временные кадры обновляются во время расчёта.").arg(point).arg(requestedPoints).arg(iteration).arg(total):tr("Точка %1 из %2: SU2, итерация %3 из %4. Поле справа обновляется во время расчёта.").arg(point).arg(requestedPoints).arg(iteration).arg(total));
                } else {progressBar->setRange(0,std::max(total,1));progressBar->setValue(total);progressBar->setFormat(tr("Точка рассчитана — 100%"));status->setText(tr("Точка %1 из %2 рассчитана: загружаются итоговые поля.").arg(point).arg(requestedPoints));}
            }
        });
        connect(&process,&QProcess::errorOccurred,this,[this](QProcess::ProcessError error){if(error==QProcess::FailedToStart){run->setEnabled(true);cancel->setEnabled(false);status->setText(process.errorString());}});
        connect(&process,qOverload<int,QProcess::ExitStatus>(&QProcess::finished),this,[this](int code,QProcess::ExitStatus){run->setEnabled(true);cancel->setEnabled(false);if(!processBuffer.trimmed().isEmpty())log->appendPlainText(processBuffer.trimmed());processBuffer.clear(); if(QFile::exists(directory+"/result.json"))load(directory+"/result.json"); else status->setText(stopping?tr("Расчёт остановлен. Последнее доступное поле сохранено справа."):tr("Расчёт завершился с кодом %1. Подробности в журнале.").arg(code));});
    }
    ~Study() override = default;
    // Time the series will take, from costs measured on this machine class (four performance
    // cores, nothing else running): Netgen ≈ 0.03 ms per cell, once per series (406 thousand cells
    // in 13 s); SU2 ≈ 1.3 µs per cell and iteration, per point (0.5 s per iteration there). The cell count follows from the wetted area, the surface step and the prism layers
    // (the wing: 52 thousand surface triangles, 27 layers → 1.66 million cells).
    void estimateTime() {
        if(!timeEstimate||!settings)return;
        const auto json=QJsonDocument::fromJson(settings->toPlainText().toUtf8()).object();
        double wetted=0;
        const auto& v=construction.mesh.vertices;const auto& idx=construction.mesh.indices;
        for(std::size_t i=0;i+2<idx.size();i+=3){
            const SbVec3f a(v[3*idx[i]],v[3*idx[i]+1],v[3*idx[i]+2]),b(v[3*idx[i+1]],v[3*idx[i+1]+1],v[3*idx[i+1]+2]),c(v[3*idx[i+2]],v[3*idx[i+2]+1],v[3*idx[i+2]+2]);
            wetted+=0.5*double((b-a).cross(c-a).length());
        }
        const double step=json["wallSizeM"].toDouble();
        if(!(wetted>0)||!(step>0)){timeEstimate->clear();return;}
        const int layers=json["layerHeightsM"].toArray().size();
        const double cells=wetted/(0.433*step*step)*(layers+5);
        const bool unsteady=model->currentData().toString()==QStringLiteral("urans_sst");
        const double iterations=unsteady?json["timeSteps"].toDouble()*json["innerIterations"].toDouble():json["iterations"].toDouble();
        const double threads=std::max(1,json["threads"].toInt(4));
        const int count=std::max<int>(1,alpha->text().split(';',Qt::SkipEmptyParts).size())*std::max<int>(1,beta->text().split(';',Qt::SkipEmptyParts).size());
        const double meshMinutes=cells*5e-5/60,pointMinutes=cells*iterations*1.3e-6*4.0/threads/60;
        auto minutes=[](double m){return m<90?tr("%1 мин").arg(std::max(1.0,std::round(m))):tr("%1 ч").arg(m/60,0,'f',1);};
        const QString size=cells>=1e6?tr("%1 млн").arg(cells/1e6,0,'f',1):tr("%1 тыс.").arg(cells/1e3,0,'f',0);
        timeEstimate->setText(count==1
            ? tr("≈ %1 ячеек. Сетка ≈ %2, расчёт ≈ %3, всего ≈ %4.").arg(size,minutes(meshMinutes),minutes(pointMinutes),minutes(meshMinutes+pointMinutes))
            : tr("≈ %1 ячеек. Сетка ≈ %2, углов %3 по ≈ %4, всего ≈ %5.").arg(size,minutes(meshMinutes)).arg(count).arg(minutes(pointMinutes),minutes(meshMinutes+count*pointMinutes)));
    }
    void openSaved(const QString& path,const QString& prefix){
        showingSaved=true;
        load(path);run->setEnabled(false);
        const auto params=result["settings"].toObject(),reference=params["reference"].toObject();
        speed->setValue(params["speedMps"].toDouble());area->setValue(reference["areaM2"].toDouble());spanBox->setValue(reference["spanM"].toDouble());chordBox->setValue(reference["chordM"].toDouble());model->setCurrentIndex(model->findData(params["model"].toString()));wallMode->setCurrentIndex(std::max(0,wallMode->findData(params["wallTreatment"].toString("resolved"))));transition->setCurrentIndex(std::max(0,transition->findData(params["transition"].toString("none"))));turbulence->setValue(params["turbulenceIntensity"].toDouble(.01)*100);
        auto angleText=[](const QJsonArray& values){QStringList parts;for(const auto& v:values)parts<<QString::number(v.toDouble());return parts.join(QStringLiteral("; "));};
        alpha->setText(angleText(params["alphaDeg"].toArray()));beta->setText(angleText(params["betaDeg"].toArray()));
        settings->setPlainText(QJsonDocument(params).toJson(QJsonDocument::Indented));
        if(!prefix.isEmpty()){
            // Documentation frames: the 3D flow twice (the arrows move between them), the pressure
            // on the body, the section, and the report tab.
            auto save=[this](const QString& target){const bool ok=resultView->capture().save(target);if(!ok)QApplication::exit(3);return ok;};
            QTimer::singleShot(1200,this,[save,prefix]{save(prefix+"-1.png");});
            QTimer::singleShot(1800,this,[this,save,prefix]{save(prefix+"-2.png");resultView->viewPreset(1);});
            QTimer::singleShot(2100,this,[this,save,prefix]{save(prefix+"-rear.png");resultView->viewPreset(0);resultView->setModeIndex(1);});
            QTimer::singleShot(2400,this,[this,save,prefix]{save(prefix+"-pressure.png");resultView->setModeIndex(2);});
            QTimer::singleShot(3600,this,[this,save,prefix]{save(prefix+"-section.png");resultTabs->setCurrentIndex(1);
                QTimer::singleShot(150,this,[this,prefix]{QApplication::exit(grab().save(prefix+"-report.png")?0:3);});});
        }
    }
    void reject() override {
        if(process.state()!=QProcess::NotRunning) status->setText(tr("Сначала остановите расчёт кнопкой «Остановить»."));
        else QDialog::reject();
    }
    void closeEvent(QCloseEvent* event) override {if(process.state()!=QProcess::NotRunning){status->setText(tr("Сначала остановите расчёт кнопкой «Остановить»."));event->ignore();}else QDialog::closeEvent(event);}
    // The section plane of this result: the one the solver reduced its time frames to, when it did,
    // so the playback and the saved frames are the same plane; otherwise halfway along the walls.
    double sectionPlane(double fallback) const {
        QFile file(QDir(directory).filePath(QStringLiteral("flow/section.json")));
        if(!file.open(QIODevice::ReadOnly))return fallback;
        const QJsonObject section=QJsonDocument::fromJson(file.readAll()).object();
        const QJsonValue plane=section.value(QStringLiteral("planeY"));
        return plane.isDouble()?plane.toDouble():fallback;
    }
    void preview() { resultView->showGeometry(construction); }
    void refreshFrames() {
        timeFrameSuffixes.clear();currentFieldSuffix.clear();timeFrameIndex=0;
        if(points->currentIndex()<0||directory.isEmpty())return;
        const QDir point(QDir(directory).filePath(points->currentData().toString()));
        for(const auto& frame:point.entryList({"volume_*.csv"},QDir::Files,QDir::Name))timeFrameSuffixes<<frame.mid(6,frame.size()-10);
        if(!timeFrameSuffixes.isEmpty()){timeFrameIndex=timeFrameSuffixes.size()-1;currentFieldSuffix=timeFrameSuffixes.last();}
    }
    void start() {
        coefficientPlot->samples={};coefficientPlot->update();coefficientTable->setRowCount(0);reportConditions->clear();
        QJsonParseError error; auto doc=QJsonDocument::fromJson(settings->toPlainText().toUtf8(),&error);
        if(error.error!=QJsonParseError::NoError||!doc.isObject()){QMessageBox::warning(this,tr("Параметры"),error.errorString());return;}
        directory=QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)+"/CFD/"+QUuid::createUuid().toString(QUuid::WithoutBraces);
        auto params=doc.object();const QString modelId=model->currentData().toString();params["model"]=modelId;params["wallTreatment"]=wallMode->currentData().toString();params["transition"]=transition->isEnabled()?transition->currentData().toString():QStringLiteral("none");params["turbulenceIntensity"]=turbulence->value()/100;params["speedMps"]=speed->value();auto reference=params["reference"].toObject();reference["areaM2"]=area->value();reference["spanM"]=spanBox->value();reference["chordM"]=chordBox->value();params["reference"]=reference;
        if(modelId==QStringLiteral("euler"))params["layerHeightsM"]=QJsonArray();
        else if(params["layerHeightsM"].toArray().isEmpty()){const double first=std::max(.00001,params["wallSizeM"].toDouble()*.025);QJsonArray layers;for(double factor:{1.,1.5,2.25,3.375,5.0625})layers.append(first*factor);params["layerHeightsM"]=layers;}
        bool anglesValid=true;auto angles=[&](QString text){QJsonArray values;for(auto part:text.split(';')){bool ok;double value=part.trimmed().replace(',','.').toDouble(&ok);anglesValid &= ok&&std::isfinite(value);values.append(value);}return values;};
        params["alphaDeg"]=angles(alpha->text());params["betaDeg"]=angles(beta->text());
        if(!anglesValid){QMessageBox::warning(this,tr("Углы"),tr("Введите числа через точку с запятой: -5; 0; 5."));return;}
        QJsonArray geometry; int i=0;
        for(const auto& body:construction.bodies)geometry.append(QJsonObject{{"id",QString::fromStdString(body.id)},{"path",QString("body-%1.brep").arg(i++)},{"sha256",QString::fromStdString(body.brepSha256)}});
        QJsonObject job{{"schema","cadnext-aerodynamics-job/1"},{"solverPath",solver->text()},{"resultPath","result.json"},{"workDirectory","flow"},{"cadAxes",QJsonObject{{"lengthUnit","m"},{"forward",QString::fromStdString(construction.cadAxes.forward)},{"up",QString::fromStdString(construction.cadAxes.up)}}},{"geometry",geometry},{"settings",params}};
        auto bytes=QJsonDocument(job).toJson(); auto valid=cfd::parseAeroJob(bytes.toStdString(),directory.toStdString());
        if(!valid.isOk()){QMessageBox::warning(this,tr("Параметры"),QString::fromStdString(valid.error().message));return;}
        if(!QFileInfo(adapter->text()).isExecutable()||!QFileInfo(solver->text()).isExecutable()){QMessageBox::warning(this,tr("Решатель не найден"),tr("Укажите существующие исполняемые файлы CFD-модуля и SU2."));return;}
        if(!QDir().mkpath(directory)){status->setText(tr("Не удалось создать папку расчёта."));return;}
        auto write=[&](QString path,QByteArray data){QFile f(directory+"/"+path);return f.open(QIODevice::WriteOnly)&&f.write(data)==data.size();};
        i=0; for(const auto& body:construction.bodies)if(!write(QString("body-%1.brep").arg(i++),QByteArray::fromStdString(body.brep))){status->setText(tr("Ошибка записи геометрии."));return;}
        if(!write("job.json",bytes)){status->setText(tr("Ошибка записи задания."));return;}
        result=QJsonObject{{"settings",params}};provisionalField=false;requestedPoints=params["alphaDeg"].toArray().size()*params["betaDeg"].toArray().size();liveFieldSignature.clear();pendingFieldSignature.clear();timeFrameSuffixes.clear();currentFieldSuffix.clear();processBuffer.clear();convergenceStatus->setText(tr("Ожидание истории сходимости…"));
        points->blockSignals(true);points->clear();points->addItem(tr("В РАСЧЁТЕ: точка 1 из %1").arg(requestedPoints),QStringLiteral("flow/point-0"));points->setCurrentIndex(0);points->blockSignals(false);points->setEnabled(false);
        preview();log->clear();progressBar->setRange(0,0);progressBar->setFormat(tr("Запуск расчёта…"));run->setEnabled(false);cancel->setEnabled(true);stopping=false;
        status->setText(tr("Расчёт: построение сетки → SU2 → проверка сходимости. Журнал слева; результаты сохраняются в папке расчёта."));
        process.setWorkingDirectory(directory);process.start(adapter->text(),{directory+"/job.json"});
    }
    void load(const QString& path) {
        QFile f(path);if(!f.open(QIODevice::ReadOnly))return;auto loaded=QJsonDocument::fromJson(f.readAll()).object();
        if(loaded["schema"]!="cadnext-aerodynamics-result/1"){QMessageBox::warning(this,tr("Результат"),tr("Это не результат CFD."));return;}
        directory=QFileInfo(path).absolutePath(); result=loaded;provisionalField=false;progressBar->setRange(0,100);progressBar->setValue(100);progressBar->setFormat(tr("Расчёт завершён — %p%"));points->blockSignals(true);points->clear();
        coefficientPlot->samples=result["points"].toArray();coefficientPlot->update();coefficientTable->setRowCount(coefficientPlot->samples.size());
        const QStringList keys{"alphaDeg","betaDeg","cl","cd","cm","cy","cRoll","cYaw","residual","iterations"};int row=0;for(auto value:coefficientPlot->samples){auto sample=value.toObject();for(int c=0;c<keys.size();++c)coefficientTable->setItem(row,c,new QTableWidgetItem(sample[keys[c]].isDouble()?QString::number(sample[keys[c]].toDouble(),'g',7):QStringLiteral("—")));++row;}
        QStringList notes;notes<<tr("Результат: %1").arg(result["outcome"].toString())<<tr("CL — подъёмная сила; CD — сопротивление; CY — боковая сила. Пространственная погрешность требует сравнения сеток.");for(const auto& key:{"warnings","failureReasons"})for(auto note:result[key].toArray())notes<<note.toString();notes<<tr("Условия и воспроизводимость:")<<QString::fromUtf8(QJsonDocument(result).toJson(QJsonDocument::Indented));reportConditions->setPlainText(notes.join('\n'));
        {
            const auto metrics=result["metrics"].toObject();
            const QString wall=metrics.contains("wallYPlusMedian")
                ? tr(" y⁺ на стенке: медиана %1, максимум %2.").arg(metrics["wallYPlusMedian"].toObject()["value"].toDouble(),0,'g',3)
                      .arg(metrics["wallYPlusMaximum"].toObject()["value"].toDouble(),0,'g',3)
                : QString();
            convergenceStatus->setText(result["outcome"].toString()=="error"
                ? tr("Расчёт не завершён. Причина указана под полем и в журнале.")
                : result["coefficientsUsable"].toBool(true)
                    ? tr("Точки прошли проверку сходимости и пристеночного разрешения.%1 Пространственная погрешность требует сравнения сеток.").arg(wall)
                    : tr("Поля рассчитаны, коэффициенты использовать нельзя — причины перечислены ниже.%1").arg(wall));
        }
        for(const auto& value:result["points"].toArray()){
            auto p=value.toObject();
            const bool usable=p["usable"].toBool(true);
            // A point that ran but did not earn its coefficients still owns its fields: it is listed,
            // opened and animated like any other, and only its numbers are marked as unusable.
            points->addItem(QString(usable?"":"НЕ ДЛЯ РАСЧЁТА · ")+QString("α %1° · β %2° · CL %3 · CD %4").arg(p["alphaDeg"].toDouble()).arg(p["betaDeg"].toDouble()).arg(p["cl"].toDouble()).arg(p["cd"].toDouble()),p["directory"].toString());
        }
        provisionalField=!result["coefficientsUsable"].toBool(true);
        if(points->count()==0) {
            const QDir flow(QDir(directory).filePath("flow"));
            for(const auto& point:flow.entryList({"point-*"},QDir::Dirs|QDir::NoDotAndDotDot,QDir::Name)) {
                const auto relative=QStringLiteral("flow/")+point;
                const QDir pointDirectory(QDir(directory).filePath(relative));
                if(QFile::exists(pointDirectory.filePath("surface.csv"))||!pointDirectory.entryList({"surface_*.csv"},QDir::Files).isEmpty())
                    points->addItem(tr("ПРЕДВАРИТЕЛЬНО: %1 — критерий сходимости не выполнен").arg(point),relative);
            }
            provisionalField=provisionalField||points->count()>0;
        }
        points->setEnabled(points->count()>0);
        points->blockSignals(false);refreshFrames();log->appendPlainText(QString::fromUtf8(QJsonDocument(result["warnings"].toArray()).toJson()));log->appendPlainText(QString::fromUtf8(QJsonDocument(result["failureReasons"].toArray()).toJson())); fields();
    }
    void fields() {
        if(points->currentIndex()<0){preview();status->setText(tr("Нет рассчитанных точек. Причина указана в журнале."));return;}
        detail::FlowResultView::Point point;
        point.directory=QDir(directory).filePath(points->currentData().toString());
        point.fieldSuffix=currentFieldSuffix;
        point.settings=result["settings"].toObject();
        QFile plane(QDir(directory).filePath(QStringLiteral("flow/section.json")));
        if(plane.open(QIODevice::ReadOnly)){
            const QJsonObject section=QJsonDocument::fromJson(plane.readAll()).object();
            const QJsonValue value=section.value(QStringLiteral("planeY"));
            point.haveSectionPlane=value.isDouble();point.sectionPlane=value.toDouble();
        }
        point.playFrames=process.state()==QProcess::NotRunning;
        QString problem;
        if(!resultView->showPoint(point,problem)){status->setText(problem);return;}
        QStringList failures;for(auto reason:result["failureReasons"].toArray())failures<<reason.toString();
        // Say what is wrong with the flow, not that something is wrong: the reasons name the
        // Reynolds number, the y+ regime or the equation that did not converge.
        status->setText(provisionalField
            ? tr("Картину можно смотреть, коэффициенты использовать нельзя: %1").arg(failures.mid(0,2).join("; "))
            : process.state()!=QProcess::NotRunning ? tr("Расчёт идёт: показано последнее записанное поле.") : tr("Расчёт завершён, коэффициенты прошли проверки."));
    }
};
}
void showAerodynamicsStudy(bridge::ConstructionDescriptor construction,QWidget* parent){(new Study(std::move(construction),parent))->show();}
void showAerodynamicsResult(const QString& path,const QString& prefix,QWidget* parent){auto* window=new Study({},parent);window->show();window->openSaved(path,prefix);}
}
