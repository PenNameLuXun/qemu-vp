// SPDX-License-Identifier: GPL-2.0-or-later
//
// Minimal Qt6 Widgets demo for the jxl playground's PL111 framebuffer.
// Renders a centered, animated label via the linuxfb QPA plugin; QTimer
// updates the text every 500 ms so a viewer can confirm the framebuffer
// is being refreshed end-to-end (no input plumbing required).
//
// Run on the guest with:
//   QT_QPA_PLATFORM=linuxfb QT_QPA_FB_TTY=/dev/null qt-gui-demo
//
// The QT_QPA_FB_TTY=/dev/null suppresses linuxfb's attempt to grab a vt
// switch, which we don't need here.

#include <QApplication>
#include <QLabel>
#include <QTimer>
#include <QDateTime>

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    QLabel label;
    label.setAlignment(Qt::AlignCenter);
    label.setStyleSheet(
        "background: #102040; color: #e0e8ff;"
        " font-size: 28px; font-family: 'DejaVu Sans';");
    label.resize(800, 600);
    label.setText(QStringLiteral(
        "Hello from jxl + linuxfb!\n"
        "Qt %1 on aarch64").arg(QT_VERSION_STR));
    label.show();

    int n = 0;
    QTimer t;
    QObject::connect(&t, &QTimer::timeout, [&]() {
        const QString stamp = QDateTime::currentDateTime().toString(
            QStringLiteral("hh:mm:ss"));
        label.setText(QStringLiteral(
            "Hello from jxl + linuxfb!\n"
            "Qt %1 on aarch64\n"
            "tick %2  %3").arg(QT_VERSION_STR).arg(++n).arg(stamp));
    });
    t.start(500);

    return app.exec();
}
