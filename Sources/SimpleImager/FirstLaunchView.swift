import AppKit
import SwiftUI

struct FirstLaunchView: View {
    @ObservedObject var model: AppModel

    private let accent = Color(red: 0.25, green: 0.48, blue: 0.96)
    private let violet = Color(red: 0.39, green: 0.32, blue: 0.78)
    private let primaryText = Color(red: 0.92, green: 0.94, blue: 0.98)
    private let secondaryText = Color(red: 0.64, green: 0.69, blue: 0.78)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.20, blue: 0.26),
                    Color(red: 0.11, green: 0.14, blue: 0.19)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 16) {
                header

                VStack(spacing: 7) {
                    ForEach(model.runtimeReadiness.checks) { check in
                        readinessRow(check)
                    }
                }

                HStack(spacing: 10) {
                    Button(L10n.text("Настройки доступа")) {
                        model.openFullDiskAccessSettings()
                    }
                    .buttonStyle(SecondaryFirstLaunchButtonStyle())

                    Button(L10n.text("Лицензии")) {
                        model.openThirdPartyLicenses()
                    }
                    .buttonStyle(SecondaryFirstLaunchButtonStyle())

                    Spacer()

                    Button(L10n.text("Проверить снова")) {
                        model.refreshRuntimeReadiness()
                    }
                    .buttonStyle(SecondaryFirstLaunchButtonStyle())

                    Button(L10n.text("Продолжить")) {
                        model.completeFirstLaunch()
                    }
                    .buttonStyle(PrimaryFirstLaunchButtonStyle(accent: accent, violet: violet))
                    .disabled(!model.runtimeReadiness.isReady)
                }
            }
            .padding(24)
        }
        .frame(width: 590, height: 430)
        .preferredColorScheme(.dark)
        .font(.custom("Avenir Next", size: 13))
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Simple Imager готовится к работе"))
                    .font(.custom("Avenir Next Demi Bold", size: 19))
                    .foregroundStyle(primaryText)
                Text(L10n.text("Проверим совместимость, встроенные инструменты и подпись приложения."))
                    .font(.custom("Avenir Next Medium", size: 11))
                    .foregroundStyle(secondaryText)
            }
        }
    }

    private func readinessRow(_ check: RuntimeCheck) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon(for: check.state))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color(for: check.state))
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(check.title))
                    .font(.custom("Avenir Next Demi Bold", size: 12))
                    .foregroundStyle(primaryText)
                Text(L10n.text(check.detail))
                    .font(.custom("Avenir Next Medium", size: 10))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func icon(for state: RuntimeCheckState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .warning: "info.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func color(for state: RuntimeCheckState) -> Color {
        switch state {
        case .ready: accent
        case .warning: Color(red: 0.94, green: 0.66, blue: 0.25)
        case .failed: Color(red: 0.94, green: 0.33, blue: 0.39)
        }
    }
}

private struct SecondaryFirstLaunchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 10))
            .foregroundStyle(Color(red: 0.86, green: 0.89, blue: 0.95))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct PrimaryFirstLaunchButtonStyle: ButtonStyle {
    let accent: Color
    let violet: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .foregroundStyle(.white)
            .padding(.horizontal, 17)
            .frame(height: 34)
            .background(
                LinearGradient(
                    colors: [accent.opacity(configuration.isPressed ? 0.76 : 1), violet],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 10)
            )
    }
}
