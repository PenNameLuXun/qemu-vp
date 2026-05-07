// SPDX-License-Identifier: GPL-2.0-or-later
//
// Minimal headless Qt demo for the jxl playground:
//   * QCoreApplication event loop running on aarch64
//   * QHostInfo asynchronous DNS lookup over the virtio-net SLIRP link
//   * QTimer single-shot fallback so the program always exits

#include <QCoreApplication>
#include <QHostInfo>
#include <QHostAddress>
#include <QTimer>
#include <QtGlobal>
#include <QDebug>

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);

    qInfo() << "Qt" << QT_VERSION_STR << "headless demo on jxl";
    const QString host = (argc > 1) ? QString::fromLocal8Bit(argv[1])
                                    : QStringLiteral("example.com");
    qInfo() << "looking up" << host;

    QHostInfo::lookupHost(host, &app, [&app, host](const QHostInfo &info) {
        if (info.error() != QHostInfo::NoError) {
            qWarning() << "lookup failed:" << info.errorString();
        } else {
            for (const QHostAddress &addr : info.addresses())
                qInfo() << host << "->" << addr.toString();
        }
        app.quit();
    });

    // Hard timeout: 5 s. Without networking the lookup may hang.
    QTimer::singleShot(5000, &app, []() {
        qWarning() << "timed out waiting for DNS";
        QCoreApplication::exit(2);
    });

    return app.exec();
}
