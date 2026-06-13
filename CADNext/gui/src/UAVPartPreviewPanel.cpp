#include "cadnext/gui/UAVPartPreviewPanel.hpp"
#include "cadnext/gui/CADPartLibraryService.hpp"
#include "cadnext/gui/FilePreviewAssets.hpp"

#include <cmath>

#include <QFileInfo>
#include <QFormLayout>
#include <QFrame>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QMessageBox>
#include <QPixmap>
#include <QPushButton>
#include <QSizePolicy>
#include <QVBoxLayout>
#include <QWidget>

#include <Inventor/Qt/viewers/SoQtExaminerViewer.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoShapeHints.h>

namespace cadnext::gui {

namespace {

QString fmtMass(double massKg) {
    return QStringLiteral("%1 кг").arg(massKg, 0, 'f', 3);
}

QString fmtMm(double meters) {
    return QString::number(meters * 1000.0, 'f', 1);
}

QString fmtBounds(double w, double d, double h) {
    return QStringLiteral("%1 × %2 × %3 мм")
        .arg(w * 1000.0, 0, 'f', 1)
        .arg(d * 1000.0, 0, 'f', 1)
        .arg(h * 1000.0, 0, 'f', 1);
}

QString fmtCoM(const cadnext::Vector3& v) {
    return QStringLiteral("X %1 мм   Y %2 мм   Z %3 мм")
        .arg(fmtMm(v.x))
        .arg(fmtMm(v.y))
        .arg(fmtMm(v.z));
}

// Итоговый статус: 0=neutral, 1=green, 2=orange, 3=red.
struct StatusInfo { QString text; int level; };

StatusInfo computeStatus(const bridge::UAVPartDescriptor& part) {
    if (!part.mass.valid || !part.manifest.massComputed) {
        return {QStringLiteral("Масса детали не рассчитана"), 3};
    }
    if (part.attachmentPoints.empty() || !part.manifest.attachmentPointsDefined) {
        return {QStringLiteral("Добавьте точку крепления"), 2};
    }
    if (part.manifest.simulationReady) {
        return {QStringLiteral("Готова к выбору БЛА"), 1};
    }
    if (!part.manifest.readinessIssues.empty()) {
        const QString t = QString::fromStdString(
            bridge::uavpartReadinessIssueText(part.manifest.readinessIssues.front()));
        if (!t.isEmpty()) {
            return {t, 2};
        }
    }
    return {QStringLiteral("Открыта с ограничениями"), 2};
}

void applyStatusColor(QLabel* label, int level) {
    QPalette pal = label->palette();
    if (level == 1) {
        pal.setColor(QPalette::WindowText, QColor(0x00, 0x80, 0x00));
    } else if (level == 2) {
        pal.setColor(QPalette::WindowText, QColor(0xa0, 0x60, 0x00));
    } else if (level == 3) {
        pal.setColor(QPalette::WindowText, Qt::red);
    }
    label->setPalette(pal);
}

QFrame* makeSep() {
    auto* sep = new QFrame;
    sep->setFrameShape(QFrame::HLine);
    sep->setFrameShadow(QFrame::Sunken);
    return sep;
}

SoSeparator* buildMeshScene(const bridge::UAVPartVisualMesh& mesh,
                             const bridge::UAVPartMaterial& material) {
    auto* sep = new SoSeparator;

    auto* mat = new SoMaterial;
    float r = 0.55f, g = 0.65f, b = 0.75f;
    const std::string& hex = material.previewColor;
    if (hex.size() == 7 && hex[0] == '#') {
        try {
            const unsigned long rgb = std::stoul(hex.substr(1), nullptr, 16);
            r = static_cast<float>((rgb >> 16) & 0xFF) / 255.0f;
            g = static_cast<float>((rgb >> 8) & 0xFF) / 255.0f;
            b = static_cast<float>(rgb & 0xFF) / 255.0f;
        } catch (...) {}
    }
    mat->diffuseColor.setValue(r, g, b);
    mat->specularColor.setValue(0.25f, 0.25f, 0.25f);
    mat->shininess.setValue(0.4f);
    sep->addChild(mat);

    auto* hints = new SoShapeHints;
    hints->shapeType = SoShapeHints::UNKNOWN_SHAPE_TYPE;
    hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
    sep->addChild(hints);

    const std::size_t nVerts = mesh.vertices.size() / 3;
    auto* coords = new SoCoordinate3;
    coords->point.setNum(static_cast<int>(nVerts));
    SbVec3f* pts = coords->point.startEditing();
    for (std::size_t i = 0; i < nVerts; ++i) {
        pts[i] = SbVec3f(mesh.vertices[i * 3 + 0],
                         mesh.vertices[i * 3 + 1],
                         mesh.vertices[i * 3 + 2]);
    }
    coords->point.finishEditing();
    sep->addChild(coords);

    const std::size_t nTris = mesh.indices.size() / 3;
    auto* ifs = new SoIndexedFaceSet;
    ifs->coordIndex.setNum(static_cast<int>(nTris * 4));
    int32_t* ci = ifs->coordIndex.startEditing();
    for (std::size_t t = 0; t < nTris; ++t) {
        ci[t * 4 + 0] = static_cast<int32_t>(mesh.indices[t * 3 + 0]);
        ci[t * 4 + 1] = static_cast<int32_t>(mesh.indices[t * 3 + 1]);
        ci[t * 4 + 2] = static_cast<int32_t>(mesh.indices[t * 3 + 2]);
        ci[t * 4 + 3] = SO_END_FACE_INDEX;
    }
    ifs->coordIndex.finishEditing();
    sep->addChild(ifs);

    return sep;
}

} // namespace

UAVPartPreviewPanel::UAVPartPreviewPanel(const bridge::UAVPartReadResult& result,
                                          const QString& filePath,
                                          QWidget* parent)
    : QDialog(parent) {
    setWindowTitle(tr("Деталь .uavpart"));
    setMinimumWidth(500);

    const bridge::UAVPartDescriptor& part = result.part;
    const bridge::UAVPartManifest& manifest = part.manifest;
    const bridge::UAVPartMaterial& material = part.material;
    const bridge::UAVPartMassProperties& mass = part.mass;

    auto* root = new QVBoxLayout(this);
    root->setSpacing(10);

    const QString displayName = manifest.displayName.empty()
        ? QString::fromStdString(manifest.name)
        : QString::fromStdString(manifest.displayName);
    const QString fileName = QFileInfo(filePath).fileName();

    // ── Верхняя зона: превью слева + название/файл справа ──────────────────
    {
        auto* topRow = new QHBoxLayout;
        topRow->setSpacing(16);

        // Preview: либо 3D mesh, либо PNG fallback
        const bool hasRealMesh = part.visualMesh.valid && !part.visualMesh.vertices.empty();

        if (hasRealMesh) {
            // 3D Coin3D ExaminerViewer
            auto* viewerContainer = new QWidget;
            viewerContainer->setFixedSize(220, 220);

            SoSeparator* meshScene = buildMeshScene(part.visualMesh, material);
            auto* viewer = new SoQtExaminerViewer(viewerContainer);
            viewer->setDecoration(FALSE);
            viewer->setBackgroundColor(SbColor(0.13f, 0.14f, 0.17f));
            viewer->setPopupMenuEnabled(FALSE);

            auto* vRoot = new SoSeparator;
            vRoot->ref();
            vRoot->addChild(meshScene);
            viewer->setSceneGraph(vRoot);
            vRoot->unref();
            viewer->viewAll();
            viewer->show();

            if (QWidget* w = viewer->getWidget()) {
                auto* vl = new QVBoxLayout(viewerContainer);
                vl->setContentsMargins(0, 0, 0, 0);
                vl->addWidget(w);
            }
            previewViewer_ = viewer;
            topRow->addWidget(viewerContainer, 0, Qt::AlignTop);
        } else {
            // PNG fallback
            const QPixmap px = cadFilePreviewPixmap(CADFilePreviewKind::uavpart, 200);
            auto* imgLabel = new QLabel;
            imgLabel->setPixmap(px);
            imgLabel->setAlignment(Qt::AlignCenter);
            imgLabel->setFixedSize(200, 200);
            topRow->addWidget(imgLabel, 0, Qt::AlignTop);
        }

        // Название + файл + статус справа
        auto* rightCol = new QVBoxLayout;
        rightCol->setSpacing(4);

        auto* titleLabel = new QLabel(
            QStringLiteral("<b>%1</b>").arg(displayName.toHtmlEscaped()));
        titleLabel->setWordWrap(true);
        {
            QFont f = titleLabel->font();
            f.setPointSize(f.pointSize() + 1);
            titleLabel->setFont(f);
        }
        rightCol->addWidget(titleLabel);

        auto* fileLabel = new QLabel(fileName);
        fileLabel->setToolTip(filePath);
        fileLabel->setEnabled(false);
        {
            QFont f = fileLabel->font();
            f.setPointSize(f.pointSize() - 1);
            fileLabel->setFont(f);
        }
        rightCol->addWidget(fileLabel);

        rightCol->addSpacing(12);

        const auto [statusText, statusLevel] = computeStatus(part);
        auto* statusLabel = new QLabel(statusText);
        statusLabel->setWordWrap(true);
        applyStatusColor(statusLabel, statusLevel);
        rightCol->addWidget(statusLabel);

        rightCol->addStretch();
        topRow->addLayout(rightCol, 1);
        root->addLayout(topRow);
    }

    root->addWidget(makeSep());

    // ── Средняя зона: свойства детали ──────────────────────────────────────
    {
        auto* form = new QFormLayout;
        form->setSpacing(5);
        form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

        const QString materialText = material.displayName.empty()
            ? tr("—") : QString::fromStdString(material.displayName);
        form->addRow(tr("Материал:"), new QLabel(materialText));

        if (mass.valid && manifest.massComputed) {
            form->addRow(tr("Масса:"), new QLabel(fmtMass(mass.massKg)));
        } else {
            auto* lbl = new QLabel(tr("Не рассчитана"));
            QPalette pal = lbl->palette();
            pal.setColor(QPalette::WindowText, Qt::red);
            lbl->setPalette(pal);
            form->addRow(tr("Масса:"), lbl);
        }

        const bool boundsValid = mass.valid
            && mass.boundingWidth > 0.0
            && mass.boundingDepth > 0.0
            && mass.boundingHeight > 0.0;
        if (boundsValid) {
            form->addRow(tr("Габариты:"),
                         new QLabel(fmtBounds(mass.boundingWidth, mass.boundingDepth,
                                              mass.boundingHeight)));
        } else {
            form->addRow(tr("Габариты:"), new QLabel(tr("—")));
        }

        const Vector3& com = mass.centerOfMass;
        const bool comValid = mass.valid
            && std::isfinite(com.x) && std::isfinite(com.y) && std::isfinite(com.z);
        if (comValid) {
            auto* comLabel = new QLabel(fmtCoM(com));
            comLabel->setWordWrap(true);
            form->addRow(tr("Центр масс:"), comLabel);
        } else {
            form->addRow(tr("Центр масс:"), new QLabel(tr("—")));
        }

        const int ptCount = static_cast<int>(part.attachmentPoints.size());
        form->addRow(tr("Точки крепления:"),
                     new QLabel(ptCount > 0 ? QString::number(ptCount) : tr("нет")));

        root->addLayout(form);
    }

    // ── Нижняя зона: предупреждения ────────────────────────────────────────
    QStringList warnings;

    if (mass.valid && mass.massKg > 100.0) {
        warnings << tr("Масса детали превышает 100 кг (%1) — проверьте материал и геометрию.")
                        .arg(fmtMass(mass.massKg));
    }
    const bool boundsValid = mass.valid
        && mass.boundingWidth > 0.0 && mass.boundingDepth > 0.0 && mass.boundingHeight > 0.0;
    if (boundsValid) {
        const double maxDim = std::max({mass.boundingWidth, mass.boundingDepth, mass.boundingHeight});
        if (maxDim > 1.0) {
            warnings << tr("Габарит детали превышает 1 м (%1 мм) — проверьте единицы измерения.")
                            .arg(QString::number(maxDim * 1000.0, 'f', 0));
        }
    }
    if (!manifest.visualMeshStored) {
        warnings << tr("Preview mesh отсутствует — показан типовой значок файла.");
    }
    if (!manifest.geometryStored) {
        warnings << tr("Редактирование недоступно — в файле отсутствует точная CAD-геометрия.");
    }

    if (!warnings.isEmpty()) {
        root->addWidget(makeSep());
        auto* warnBox = new QGroupBox(tr("Предупреждения"));
        auto* warnLayout = new QVBoxLayout(warnBox);
        warnLayout->setSpacing(4);
        for (const QString& w : warnings) {
            auto* lbl = new QLabel(QStringLiteral("· ") + w);
            lbl->setWordWrap(true);
            QPalette pal = lbl->palette();
            pal.setColor(QPalette::WindowText, QColor(0xa0, 0x60, 0x00));
            lbl->setPalette(pal);
            warnLayout->addWidget(lbl);
        }
        root->addWidget(warnBox);
    }

    // ── Кнопки ─────────────────────────────────────────────────────────────
    root->addWidget(makeSep());

    auto* addToLibBtn = new QPushButton(tr("Добавить в библиотеку деталей"));
    auto* openForEditBtn = new QPushButton(tr("Открыть для редактирования"));
    auto* closeBtn = new QPushButton(tr("Закрыть"));

    const bool canEdit = manifest.geometryStored && part.exactGeometry.valid;
    openForEditBtn->setEnabled(canEdit);
    openForEditBtn->setDefault(canEdit);
    if (!canEdit) {
        openForEditBtn->setToolTip(
            tr("Недоступно: в файле отсутствует точная CAD-геометрия."));
    }
    closeBtn->setDefault(!canEdit);

    auto* btnRow = new QHBoxLayout;
    btnRow->addWidget(addToLibBtn);
    btnRow->addStretch();
    btnRow->addWidget(openForEditBtn);
    btnRow->addWidget(closeBtn);
    root->addLayout(btnRow);

    connect(closeBtn, &QPushButton::clicked, this, &QDialog::accept);
    connect(openForEditBtn, &QPushButton::clicked, this, [this]() {
        requestedAction_ = Action::OpenForEditing;
        accept();
    });
    connect(addToLibBtn, &QPushButton::clicked, this, [this, filePath]() {
        CADPartLibraryService::instance().addPart(filePath);
        QMessageBox::information(this, tr("Библиотека деталей"),
            tr("Деталь добавлена в библиотеку:\n%1").arg(filePath));
    });
}

UAVPartPreviewPanel::~UAVPartPreviewPanel() {
    delete previewViewer_;
}

} // namespace cadnext::gui
