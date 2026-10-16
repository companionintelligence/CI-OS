/* Companion OS installer slideshow, shown while the system is written to disk (slideshowAPI 2).
 *
 * SPDX-FileCopyrightText: no
 * SPDX-License-Identifier: CC0-1.0
 *
 * Four text slides, no pictures but the logo: nothing here depends on an image format plugin. The wording is the product copy
 * of the brand canon (CI-Common content/tokens/copy.json: products.os.tagline, taglines.primary, taglines.descriptor,
 * products.hub.tagline, products.memory.tagline). The colours are placeholders that stage-installer.sh replaces with the brand
 * tokens (see branding.desc). The Presentation / Slide types come from the installer itself (usr/share/calamares/qml/calamares/slideshow).
 */
import QtQuick 2.15;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    function nextSlide() {
        presentation.goToNextSlide();
    }

    Timer {
        id: advanceTimer
        interval: 20000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: nextSlide()
    }

    Slide {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "@SLIDE_BACKGROUND@" }
        Image {
            source: "logo.png"
            width: 96; height: 96
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: parent.height * 0.18
            fillMode: Image.PreserveAspectFit
        }
        Text {
            anchors.centerIn: parent
            text: "Companion OS"
            color: "@SLIDE_TEXT@"
            font.pixelSize: 34
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 36
            text: "The appliance operating system."
            color: "@SLIDE_TEXT@"
            font.pixelSize: 18
        }
    }

    Slide {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "@SLIDE_BACKGROUND@" }
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "The AI That You Own\n\nSelf-hosted AI, private memory, and a personal app store on hardware you control."
            color: "@SLIDE_TEXT@"
            font.pixelSize: 22
        }
    }

    Slide {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "@SLIDE_BACKGROUND@" }
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Companion Hub\n\nYour personal cloud. Runs on any machine."
            color: "@SLIDE_TEXT@"
            font.pixelSize: 22
        }
    }

    Slide {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "@SLIDE_BACKGROUND@" }
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Companion Memory\n\nYour AI remembers, because it's yours."
            color: "@SLIDE_TEXT@"
            font.pixelSize: 22
        }
    }

    function onActivate() {
        presentation.currentSlide = 0;
    }

    function onLeave() {
    }
}
