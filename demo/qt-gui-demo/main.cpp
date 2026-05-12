// SPDX-License-Identifier: GPL-2.0-or-later
//
// Minimal Qt6 Widgets demo for the jxl playground's framebuffer/GPU paths
// AND its input pipeline (virtio-keyboard + virtio-tablet -> evdev -> Qt).
//
// Layout (top → bottom):
//   * animated header label (ticking timer, proves the framebuffer is alive)
//   * QLineEdit #1 -- normal echo
//   * QLineEdit #2 -- password echo
//   * mirror label   -- shows whatever was last typed into either editor
//   * mouse-pos label-- live x,y from QMouseEvent on the main window
//
// Type into the editors via the VNC client's keyboard, move the mouse to
// see the position update. If the editors don't take focus or the mirror
// stays empty, the input path is the broken link (likely Qt's evdev plugin
// didn't load, or /dev/input/event* is missing in the guest).
//
// Run on the guest with:
//   QT_QPA_PLATFORM=linuxfb QT_QPA_FB_TTY=/dev/null qt-gui-demo
//   QT_QPA_PLATFORM=eglfs QT_QPA_EGLFS_INTEGRATION=eglfs_kms qt-gui-demo
//
// QT_QPA_FB_TTY=/dev/null suppresses linuxfb's attempt to grab a vt switch.

#include <QApplication>
#include <QDateTime>
#include <QGuiApplication>
#include <QLabel>
#include <QLineEdit>
#include <QMouseEvent>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>

class DemoWindow : public QWidget
{
public:
    DemoWindow()
    {
        setStyleSheet(
            "QWidget { background: #102040; color: #e0e8ff;"
            " font-family: 'DejaVu Sans'; font-size: 20px; }"
            "QLineEdit { background: #1a3060; color: #ffffff;"
            " border: 2px solid #406080; padding: 6px;"
            " selection-background-color: #6090ff; }"
            "QLabel#header { font-size: 22px; padding: 8px; }"
            "QLabel#mirror { font-size: 18px; color: #a0e0ff;"
            " border: 1px dashed #406080; padding: 8px; min-height: 32px; }"
            "QLabel#mouse  { font-size: 16px; color: #ffd080; padding: 6px; }");

        auto *header = new QLabel(this);
        header->setObjectName("header");
        header->setAlignment(Qt::AlignCenter);

        auto *edit1 = new QLineEdit(this);
        edit1->setPlaceholderText("type here — normal echo");

        auto *edit2 = new QLineEdit(this);
        edit2->setPlaceholderText("type here — password echo");
        edit2->setEchoMode(QLineEdit::Password);

        auto *mirror = new QLabel(QStringLiteral("(nothing typed yet)"), this);
        mirror->setObjectName("mirror");
        mirror->setAlignment(Qt::AlignCenter);

        mousePosLabel_ = new QLabel(QStringLiteral("mouse: (no events yet)"), this);
        mousePosLabel_->setObjectName("mouse");
        mousePosLabel_->setAlignment(Qt::AlignCenter);

        auto *layout = new QVBoxLayout(this);
        layout->setContentsMargins(40, 40, 40, 40);
        layout->setSpacing(16);
        layout->addWidget(header);
        layout->addStretch(1);
        layout->addWidget(edit1);
        layout->addWidget(edit2);
        layout->addWidget(mirror);
        layout->addStretch(1);
        layout->addWidget(mousePosLabel_);

        auto mirrorIt = [mirror](const QString &which, const QString &text) {
            mirror->setText(QStringLiteral("%1: \"%2\"").arg(which, text));
        };
        QObject::connect(edit1, &QLineEdit::textChanged, this,
                         [mirrorIt](const QString &t) {
                             mirrorIt(QStringLiteral("edit1"), t);
                         });
        QObject::connect(edit2, &QLineEdit::textChanged, this,
                         [mirrorIt](const QString &t) {
                             mirrorIt(QStringLiteral("edit2"), t);
                         });

        const QString platform = QGuiApplication::platformName();
        auto refreshHeader = [header, platform, this]() {
            const QString stamp = QDateTime::currentDateTime().toString(
                QStringLiteral("hh:mm:ss"));
            header->setText(QStringLiteral(
                "jxl + %1 — Qt %2 on aarch64\n"
                "tick %3  %4")
                                .arg(platform,
                                     QStringLiteral(QT_VERSION_STR),
                                     QString::number(++tick_),
                                     stamp));
        };
        refreshHeader();
        auto *timer = new QTimer(this);
        QObject::connect(timer, &QTimer::timeout, this, refreshHeader);
        timer->start(500);

        edit1->setFocus();
    }

protected:
    void mouseMoveEvent(QMouseEvent *e) override
    {
        const auto p = e->position().toPoint();
        mousePosLabel_->setText(QStringLiteral("mouse move:  x=%1  y=%2")
                                    .arg(p.x()).arg(p.y()));
    }

    void mousePressEvent(QMouseEvent *e) override
    {
        const auto p = e->position().toPoint();
        const char *b = "?";
        switch (e->button()) {
        case Qt::LeftButton:   b = "left";   break;
        case Qt::RightButton:  b = "right";  break;
        case Qt::MiddleButton: b = "middle"; break;
        default: break;
        }
        mousePosLabel_->setText(QStringLiteral("mouse press: %1  x=%2  y=%3")
                                    .arg(QLatin1StringView(b))
                                    .arg(p.x()).arg(p.y()));
    }

private:
    QLabel *mousePosLabel_ = nullptr;
    int tick_ = 0;
};

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    DemoWindow w;
    w.setMouseTracking(true);     // mouseMoveEvent without needing a press
    w.resize(800, 600);
    w.show();

    return app.exec();
}
