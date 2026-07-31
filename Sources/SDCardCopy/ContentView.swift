import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.94, green: 0.93, blue: 0.86), Color(red: 0.83, green: 0.90, blue: 0.83)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.white.opacity(0.32))
                .frame(width: 430, height: 430)
                .blur(radius: 2)
                .offset(x: 330, y: -270)

            VStack(spacing: 22) {
                header
                operationSelector
                mainPanel
                statusPanel
            }
            .padding(30)
        }
        .font(.custom("Avenir Next", size: 14))
        .animation(.easeInOut(duration: 0.22), value: model.operation)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SD Архиватор")
                    .font(.custom("Avenir Next Demi Bold", size: 30))
                    .foregroundStyle(ink)
                Text("Точная копия карты без лишнего воздуха")
                    .font(.custom("Avenir Next Medium", size: 14))
                    .foregroundStyle(ink.opacity(0.62))
            }
            Spacer()
            Label("Только внешние диски", systemImage: "shield.checkered")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(moss)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.55), in: Capsule())
        }
    }

    private var operationSelector: some View {
        HStack(spacing: 6) {
            ForEach(OperationKind.allCases) { operation in
                Button {
                    guard !model.isWorking else { return }
                    model.operation = operation
                    model.imageURL = nil
                    model.progress = nil
                    model.errorMessage = nil
                } label: {
                    Label(operation.title, systemImage: operation == .create ? "archivebox" : "sdcard")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(model.operation == operation ? Color.white : ink.opacity(0.7))
                        .background(model.operation == operation ? moss : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 15))
    }

    private var mainPanel: some View {
        VStack(spacing: 18) {
            diskRow
            Divider().overlay(ink.opacity(0.12))
            fileRow
            if model.operation == .create {
                captureModeSection
            } else {
                restoreOptions
            }
            actionRow
        }
        .padding(22)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.8), lineWidth: 1))
        .shadow(color: ink.opacity(0.08), radius: 18, y: 9)
    }

    private var diskRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(model.operation == .create ? "Исходная SD-карта" : "Целевая SD-карта", systemImage: "externaldrive")
                    .font(.custom("Avenir Next Demi Bold", size: 13))
                    .foregroundStyle(ink)
                Spacer()
                Button {
                    Task { await model.refreshDisks() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isWorking || model.isRefreshing)
                .help("Обновить список дисков")
            }

            if model.disks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sdcard")
                        .font(.title2)
                        .foregroundStyle(terracotta)
                    Text("Подключите SD-карту через кардридер и нажмите обновить.")
                        .foregroundStyle(ink.opacity(0.65))
                    Spacer()
                }
                .padding(13)
                .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Picker("", selection: $model.selectedDiskID) {
                    ForEach(model.disks) { disk in
                        Text("\(disk.displayName)  [\(disk.devicePath)]").tag(Optional(disk.identifier))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(model.isWorking)
            }
        }
    }

    private var fileRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.operation == .create ? "Файл образа" : "Образ для записи")
                .font(.custom("Avenir Next Demi Bold", size: 13))
                .foregroundStyle(ink)
            HStack(spacing: 10) {
                Image(systemName: model.imageURL == nil ? "doc.badge.plus" : "doc.zipper")
                    .foregroundStyle(model.imageURL == nil ? ink.opacity(0.35) : moss)
                Text(model.imageURL?.path ?? "Файл пока не выбран")
                    .font(.custom("SF Mono", size: 11))
                    .foregroundStyle(ink.opacity(model.imageURL == nil ? 0.45 : 0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(model.operation == .create ? "Выбрать место…" : "Открыть…") {
                    if model.operation == .create { model.chooseImageLocation() }
                    else { model.chooseExistingImage() }
                }
                .disabled(model.isWorking)
            }
            .padding(12)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var captureModeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Как создать образ")
                .font(.custom("Avenir Next Demi Bold", size: 13))
                .foregroundStyle(ink)
            HStack(spacing: 10) {
                ForEach(CaptureMode.allCases) { mode in
                    Button {
                        model.captureMode = mode
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(mode.title)
                                    .font(.custom("Avenir Next Demi Bold", size: 13))
                                Spacer()
                                Image(systemName: model.captureMode == mode ? "checkmark.circle.fill" : "circle")
                            }
                            Text(mode.explanation)
                                .font(.custom("Avenir Next", size: 11))
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(ink.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(model.captureMode == mode ? moss : ink)
                        .background(
                            model.captureMode == mode ? moss.opacity(0.10) : Color.black.opacity(0.025),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(model.captureMode == mode ? moss.opacity(0.55) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isWorking)
                }
            }
            Text("Компактный образ остается образом исходного размера: для восстановления нужна карта того же или большего объема.")
                .font(.custom("Avenir Next Medium", size: 11))
                .foregroundStyle(terracotta)
        }
    }

    private var restoreOptions: some View {
        Toggle(isOn: $model.verifyAfterRestore) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Проверить карту после записи")
                    .font(.custom("Avenir Next Demi Bold", size: 13))
                Text("Медленнее, зато каждый записанный байт сверяется с образом.")
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(ink.opacity(0.58))
            }
        }
        .toggleStyle(.switch)
        .disabled(model.isWorking)
    }

    private var actionRow: some View {
        HStack {
            if PrivilegedHelperLauncher.zstdPath() == nil {
                Label("Не найден zstd", systemImage: "exclamationmark.triangle")
                    .font(.custom("Avenir Next Demi Bold", size: 12))
                    .foregroundStyle(terracotta)
            } else {
                Label("Исходная карта не изменяется", systemImage: "lock.shield")
                    .font(.custom("Avenir Next Medium", size: 11))
                    .foregroundStyle(ink.opacity(0.5))
            }
            Spacer()
            if model.isWorking {
                Button("Отменить", role: .cancel) { model.cancel() }
            } else {
                Button {
                    model.start()
                } label: {
                    Label(
                        model.operation == .create ? "Создать сжатый образ" : "Стереть и записать карту",
                        systemImage: model.operation == .create ? "arrow.down.doc" : "arrow.down.to.line.compact"
                    )
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.operation == .create ? moss : terracotta)
                .controlSize(.large)
                .disabled(!model.canStart)
            }
        }
    }

    @ViewBuilder
    private var statusPanel: some View {
        if let progress = model.progress {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(progress.phase.title)
                        .font(.custom("Avenir Next Demi Bold", size: 13))
                    Spacer()
                    if progress.totalBytes > 0 {
                        Text("\(Int(progress.fraction * 100))%")
                            .font(.custom("SF Mono", size: 12))
                    }
                }
                ProgressView(value: progress.fraction)
                    .tint(progress.phase == .failed ? terracotta : moss)
                Text(progress.message)
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(progress.phase == .failed ? terracotta : ink.opacity(0.62))
            }
            .padding(.horizontal, 4)
        } else if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(terracotta)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ink: Color { Color(red: 0.13, green: 0.18, blue: 0.16) }
    private var moss: Color { Color(red: 0.16, green: 0.39, blue: 0.28) }
    private var terracotta: Color { Color(red: 0.69, green: 0.28, blue: 0.18) }
}
