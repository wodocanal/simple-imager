import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Namespace private var modeHighlight
    @State private var hasAppeared = false
    @State private var showsSettings = false
    @State private var showsFAQ = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                workflow
                    .frame(width: 540)
                    .padding(.top, 18)
                Spacer(minLength: 10)
                progressArea
                    .frame(width: 540)
                    .padding(.bottom, 10)
                primaryAction
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .ignoresSafeArea(.container, edges: .top)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 14)
        }
        .preferredColorScheme(.dark)
        .font(.custom("Avenir Next", size: 14))
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                hasAppeared = true
            }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.19, green: 0.23, blue: 0.30),
                    Color(red: 0.157, green: 0.192, blue: 0.251),
                    Color(red: 0.12, green: 0.15, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [accentBlue.opacity(0.13), Color.clear],
                center: UnitPoint(x: 0.16, y: 0.02),
                startRadius: 10,
                endRadius: 470
            )

            RadialGradient(
                colors: [accentViolet.opacity(0.10), Color.clear],
                center: UnitPoint(x: 0.92, y: 0.55),
                startRadius: 10,
                endRadius: 520
            )

            GridBackdrop()
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        ZStack {
            HStack {
                Text("DRIVE IMAGE")
                    .font(.custom("Avenir Next Demi Bold", size: 10))
                    .tracking(1.2)
                    .foregroundStyle(primaryText)
                    .padding(.leading, 48)
                Spacer()
                HStack(spacing: 6) {
                    utilityButton(icon: "gearshape.fill", help: "Настройки") {
                        showsSettings.toggle()
                    }
                    .popover(isPresented: $showsSettings, arrowEdge: .top) {
                        settingsPopover
                    }

                    utilityButton(icon: "questionmark.circle.fill", help: "FAQ") {
                        showsFAQ.toggle()
                    }
                    .popover(isPresented: $showsFAQ, arrowEdge: .top) {
                        faqPopover
                    }
                }
            }
            modeSelector
        }
        .frame(height: 42)
    }

    private var modeSelector: some View {
        HStack(spacing: 5) {
            ForEach(OperationKind.allCases) { operation in
                Button {
                    select(operation)
                } label: {
                    ZStack {
                        if model.operation == operation {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(LinearGradient(colors: [accentBlue, accentViolet], startPoint: .leading, endPoint: .trailing))
                                .matchedGeometryEffect(id: "mode", in: modeHighlight)
                        }

                        Label(
                            operation.title,
                            systemImage: operation == .create ? "arrow.down.doc" : "arrow.down.to.line"
                        )
                        .font(.custom("Avenir Next Demi Bold", size: 10))
                        .foregroundStyle(model.operation == operation ? Color.white : secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
            }
        }
        .padding(4)
        .frame(width: 300, height: 40)
        .background(surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func utilityButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(primaryText)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Настройки")
                    .font(.custom("Avenir Next Demi Bold", size: 16))
                    .foregroundStyle(primaryText)
                Text("Параметры следующего образа")
                    .font(.custom("Avenir Next Medium", size: 10))
                    .foregroundStyle(secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Обработка образа по умолчанию")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(primaryText)
                Picker("", selection: $model.processingMode) {
                    Text("Без изменений").tag(ImageProcessingMode.exact)
                    Text("Обнулить").tag(ImageProcessingMode.optimizeFreeSpace)
                    Text("Уменьшить").tag(ImageProcessingMode.shrinkExt)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(model.isWorking)

                Toggle("Расширять ext при первой загрузке", isOn: $model.autoExpandShrunkExt)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.custom("Avenir Next Medium", size: 10))
                    .foregroundStyle(primaryText)
                    .disabled(model.isWorking)
            }

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 9) {
                Text("Автоматически извлекать носитель")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(primaryText)

                Toggle("После считывания образа", isOn: $model.ejectAfterCreate)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Toggle("После записи образа", isOn: $model.ejectAfterRestore)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .font(.custom("Avenir Next Medium", size: 10))
            .foregroundStyle(primaryText)
            .disabled(model.isWorking)

            Divider().overlay(Color.white.opacity(0.08))

            let codecAvailable = model.imageCompression.isAvailable(for: .encode)
            Label(
                codecAvailable
                    ? "Формат .\(model.selectedFormat.fileSuffix) готов"
                    : "Для \(model.imageCompression.shortTitle) нужен внешний кодек",
                systemImage: codecAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.custom("Avenir Next Medium", size: 10))
            .foregroundStyle(codecAvailable ? accentBlue : warning)
        }
        .padding(18)
        .frame(width: 300)
        .background(Color(red: 0.13, green: 0.16, blue: 0.21))
    }

    private var faqPopover: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Коротко о работе")
                .font(.custom("Avenir Next Demi Bold", size: 16))
                .foregroundStyle(primaryText)

            faqItem(
                title: "Какие носители поддерживаются?",
                text: "Внешние SD-карты, USB-флешки, SSD и жесткие диски, которые macOS видит как физический диск."
            )
            faqItem(
                title: "Что делает обнуление пустот?",
                text: "Свободные кластеры FAT32 и exFAT превращаются в нули. Без сжатия создаётся sparse-образ: полный логический размер, но меньше занятого места на диске."
            )
            faqItem(
                title: "Что делает уменьшение ext?",
                text: "Уменьшает последний основной раздел ext2/3/4 в MBR, зануляет свободные блоки и может расширить rootfs при первой загрузке. Работает без Docker, но требует e2fsprogs."
            )
            faqItem(
                title: "Какие образы поддерживаются?",
                text: "IMG, RAW и DD без сжатия или в ZSTD, GZIP, XZ, BZIP2, LZ4, ZIP и 7Z. Отдельный JSON не создается."
            )
            faqItem(
                title: "Можно ли записать на меньший диск?",
                text: "Да, если образ был уменьшен. Целевой носитель должен вмещать итоговый логический размер файла."
            )
        }
        .padding(18)
        .frame(width: 340)
        .background(Color(red: 0.13, green: 0.16, blue: 0.21))
    }

    private func faqItem(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 11))
                .foregroundStyle(primaryText)
            Text(text)
                .font(.custom("Avenir Next Medium", size: 10))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var workflow: some View {
        VStack(spacing: 6) {
            if model.operation == .create {
                StepSection(number: "01", title: "Выберите носитель") {
                    devicePicker(isTarget: false)
                }

                StepSection(number: "02", title: "Название и расположение образа") {
                    imageDestinationEditor
                }

                StepSection(number: "03", title: "Свободное место и сжатие") {
                    imageOptions
                }
            } else {
                StepSection(number: "01", title: "Источник образа") {
                    restoreSourceControls
                }

                StepSection(number: "02", title: "Выберите целевой носитель") {
                    devicePicker(isTarget: true)
                }
            }
        }
        .id(model.operation)
        .transition(.opacity.combined(with: .move(edge: model.operation == .create ? .leading : .trailing)))
    }

    private func devicePicker(isTarget: Bool) -> some View {
        let candidates = isTarget ? model.availableTargetDisks : model.disks
        let selected = model.selectedDisk.flatMap { disk in
            candidates.contains(where: { $0.identifier == disk.identifier }) ? disk : nil
        }
        return VStack(spacing: 7) {
            HStack(spacing: 10) {
                if let disk = selected {
                    Menu {
                        ForEach(candidates) { candidate in
                            Button {
                                model.selectTargetDisk(candidate.identifier)
                            } label: {
                                Text("\(candidate.displayName)  [\(candidate.devicePath)]")
                            }
                        }
                    } label: {
                        HStack(spacing: 11) {
                            deviceIcon(isTarget: isTarget)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(disk.mediaName)
                                    .font(.custom("Avenir Next Demi Bold", size: 14))
                                    .foregroundStyle(primaryText)
                                Text("\(disk.devicePath)  ·  \(formattedSize(disk.size))")
                                    .font(.custom("SF Mono", size: 10))
                                    .foregroundStyle(secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(secondaryText)
                        }
                        .padding(10)
                        .background(fieldSurface, in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.07), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(model.isWorking)
                } else {
                    HStack(spacing: 11) {
                        deviceIcon(isTarget: isTarget)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.isRefreshing ? "Ищем внешние накопители…" : "Носитель не найден")
                                .font(.custom("Avenir Next Demi Bold", size: 12))
                                .foregroundStyle(primaryText)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(fieldSurface, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.07), lineWidth: 1))
                }

                Button {
                    Task { await model.refreshDisks() }
                } label: {
                    Group {
                        if model.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .foregroundStyle(primaryText)
                    .background(fieldSurface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking || model.isRefreshing)
                .help("Обновить список устройств")
            }

            if isTarget, let disk = selected {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Будет полностью очищен \(disk.devicePath). Отменить запись без потери данных нельзя.")
                    Spacer()
                }
                .font(.custom("Avenir Next Medium", size: 10))
                .foregroundStyle(warning)
            }
        }
    }

    private func deviceIcon(isTarget: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill((isTarget ? accentViolet : accentBlue).opacity(0.14))
            Image(systemName: isTarget ? "externaldrive.fill.badge.minus" : "externaldrive.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isTarget ? accentViolet : accentBlue)
        }
        .frame(width: 34, height: 34)
    }

    private var imageDestinationEditor: some View {
        HStack(spacing: 8) {
            Button(action: model.chooseOutputDirectory) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accentBlue)
                    Text(model.outputDirectoryURL?.lastPathComponent ?? "Расположение")
                        .font(.custom("Avenir Next Demi Bold", size: 10))
                        .foregroundStyle(model.outputDirectoryURL == nil ? secondaryText : primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(secondaryText)
                }
                .padding(.horizontal, 10)
                .frame(width: 176, height: 42)
                .background(fieldSurface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.07), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.isWorking)
            .help(model.outputDirectoryURL?.path ?? "Выбрать папку")

            TextField(
                "Название",
                text: Binding(
                    get: { model.outputName },
                    set: model.updateOutputName
                )
            )
            .textFieldStyle(.plain)
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .foregroundStyle(primaryText)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(fieldSurface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.07), lineWidth: 1))
            .disabled(model.isWorking)

            Menu {
                ForEach(RawImageType.allCases) { type in
                    Button {
                        model.selectRawImageType(type)
                    } label: {
                        if model.rawImageType == type {
                            Label(".\(type.title)", systemImage: "checkmark")
                        } else {
                            Text(".\(type.title)")
                        }
                    }
                }
            } label: {
                Text(".\(model.rawImageType.title)")
                    .font(.custom("SF Mono", size: 10))
                    .foregroundStyle(primaryText)
                    .padding(.horizontal, 10)
                    .frame(width: 88, height: 42, alignment: .leading)
                    .background(fieldSurface, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.07), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .disabled(model.isWorking)
        }
    }

    private var restoreSourceControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                ForEach(RestoreSourceKind.allCases) { source in
                    restoreSourceOption(source)
                }
            }
            restoreSourceField
        }
    }

    private func restoreSourceOption(_ source: RestoreSourceKind) -> some View {
        let selected = model.restoreSourceKind == source
        return Button {
            model.selectRestoreSource(source)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: source.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? accentBlue : secondaryText)
                Text(source.title)
                    .font(.custom("Avenir Next Demi Bold", size: 10))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? accentBlue : secondaryText.opacity(0.65))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(selected ? accentBlue.opacity(0.09) : fieldSurface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? accentBlue.opacity(0.75) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
    }

    @ViewBuilder
    private var restoreSourceField: some View {
        switch model.restoreSourceKind {
        case .file:
            restoreImagePicker
        case .url:
            remoteURLField
        case .drive:
            sourceDrivePicker
        }
    }

    private var remoteURLField: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(accentBlue.opacity(0.12))
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accentBlue)
            }
            .frame(width: 34, height: 34)

            TextField(
                "https://example.com/image.img.xz",
                text: Binding(
                    get: { model.remoteURLText },
                    set: model.updateRemoteURL
                )
            )
            .textFieldStyle(.plain)
            .font(.custom("SF Mono", size: 10))
            .foregroundStyle(primaryText)

            if !model.remoteURLText.isEmpty {
                Button {
                    model.updateRemoteURL("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(minHeight: 54)
        .background(fieldSurface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .disabled(model.isWorking)
    }

    private var sourceDrivePicker: some View {
        let candidates = model.availableSourceDisks
        let selected = model.selectedSourceDisk.flatMap { disk in
            candidates.contains(where: { $0.identifier == disk.identifier }) ? disk : nil
        }
        return Group {
            if let disk = selected {
                Menu {
                    ForEach(candidates) { candidate in
                        Button {
                            model.selectSourceDisk(candidate.identifier)
                        } label: {
                            Text("\(candidate.displayName)  [\(candidate.devicePath)]")
                        }
                    }
                } label: {
                    HStack(spacing: 11) {
                        deviceIcon(isTarget: false)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(disk.mediaName)
                                .font(.custom("Avenir Next Demi Bold", size: 12))
                                .foregroundStyle(primaryText)
                            Text("\(disk.devicePath)  ·  \(formattedSize(disk.size))")
                                .font(.custom("SF Mono", size: 9))
                                .foregroundStyle(secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(secondaryText)
                    }
                    .padding(10)
                    .frame(minHeight: 54)
                    .background(fieldSurface, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.07), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
            } else {
                HStack(spacing: 11) {
                    deviceIcon(isTarget: false)
                    Text(model.disks.isEmpty ? "Носители не найдены" : "Подключите второй носитель")
                        .font(.custom("Avenir Next Demi Bold", size: 12))
                        .foregroundStyle(primaryText)
                    Spacer()
                }
                .padding(10)
                .frame(minHeight: 54)
                .background(fieldSurface, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.07), lineWidth: 1))
            }
        }
        .disabled(model.isWorking)
    }

    private var restoreImagePicker: some View {
        Button {
            model.chooseExistingImage()
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(accentBlue.opacity(0.12))
                    Image(systemName: model.imageURL == nil ? "doc.badge.plus" : "doc.zipper")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accentBlue)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.imageURL?.lastPathComponent ?? "Открыть файл образа")
                        .font(.custom("Avenir Next Demi Bold", size: 12))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    if let imageURL = model.imageURL {
                        Text(shortParentPath(imageURL))
                            .font(.custom("SF Mono", size: 9))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Text(model.imageURL == nil ? "Выбрать" : "Изменить")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(accentBlue)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentBlue)
            }
            .padding(10)
            .background(fieldSurface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
    }

    private var imageOptions: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                processingModeOption(mode: .exact, icon: "square.stack.3d.up.fill")
                processingModeOption(mode: .optimizeFreeSpace, icon: "eraser.fill")
                processingModeOption(mode: .shrinkExt, icon: "arrow.down.right.and.arrow.up.left")
            }
            compressionSelector
        }
    }

    private func processingModeOption(
        mode: ImageProcessingMode,
        icon: String
    ) -> some View {
        let selected = model.processingMode == mode
        return Button {
            model.processingMode = mode
            model.errorMessage = nil
            model.progress = nil
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? accentBlue : secondaryText)
                Text(mode.title)
                    .font(.custom("Avenir Next Demi Bold", size: 9))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? accentBlue : secondaryText.opacity(0.7))
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(selected ? accentBlue.opacity(0.08) : fieldSurface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(selected ? accentBlue.opacity(0.72) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
        .help(mode.explanation)
    }

    private var compressionSelector: some View {
        Menu {
            ForEach(ImageCompression.allCases) { compression in
                Button {
                    model.selectImageCompression(compression)
                } label: {
                    if model.imageCompression == compression {
                        Label(compression.title, systemImage: "checkmark")
                    } else {
                        Text(compression.title)
                    }
                }
            }
        } label: {
            formatMenuLabel(caption: "СЖАТИЕ", value: model.imageCompression.shortTitle, icon: "archivebox.fill")
        }
        .frame(maxWidth: .infinity)
        .menuStyle(.borderlessButton)
        .disabled(model.isWorking)
    }

    private func formatMenuLabel(caption: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accentBlue)
            Text("\(caption)  ·  \(value)")
                .font(.custom("Avenir Next Demi Bold", size: 8))
                .tracking(0.5)
                .foregroundStyle(primaryText)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(fieldSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    @ViewBuilder
    private var progressArea: some View {
        if let progress = model.progress {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    statusSymbol(for: progress.phase)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progress.phase.title)
                            .font(.custom("Avenir Next Demi Bold", size: 13))
                            .foregroundStyle(primaryText)
                        Text(progress.message)
                            .font(.custom("Avenir Next Medium", size: 10))
                            .foregroundStyle(progress.phase == .failed ? danger : secondaryText)
                    }
                    Spacer()
                    if progress.totalBytes > 0 {
                        Text("\(Int(progress.fraction * 100))%")
                            .font(.custom("SF Mono", size: 12))
                            .foregroundStyle(primaryText)
                    }
                }

                if progress.totalBytes > 0 {
                    ProgressView(value: progress.fraction)
                        .tint(progress.phase == .failed ? danger : accentBlue)
                } else if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accentBlue)
                }
            }
            .padding(12)
            .background(surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.07), lineWidth: 1))
        } else if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.custom("Avenir Next Medium", size: 11))
                    .foregroundStyle(danger)

                if model.needsFullDiskAccess {
                    Button(action: model.openFullDiskAccessSettings) {
                        Label("Открыть полный доступ к диску", systemImage: "gearshape.fill")
                            .font(.custom("Avenir Next Demi Bold", size: 10))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(accentBlue, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(danger.opacity(0.22), lineWidth: 1))
        }
    }

    private var primaryAction: some View {
        VStack(spacing: 7) {
            if model.isWorking {
                if model.progress?.phase == .verifyingCard {
                    actionButton(
                        title: "Пропустить проверку",
                        icon: "forward.end.fill",
                        destructive: false,
                        action: model.skipVerification
                    )
                } else {
                    actionButton(
                        title: "Остановить операцию",
                        icon: "stop.fill",
                        destructive: true,
                        action: model.cancel
                    )
                }
            } else {
                actionButton(
                    title: primaryActionTitle,
                    icon: primaryActionIcon,
                    destructive: model.operation == .restore,
                    disabled: !model.canStart,
                    action: model.start
                )
            }

            if let availabilityMessage = model.codecAvailabilityMessage {
                Label(availabilityMessage, systemImage: "exclamationmark.triangle")
                    .font(.custom("SF Mono", size: 10))
                    .foregroundStyle(warning)
            }
        }
    }

    private var primaryActionTitle: String {
        guard model.operation == .restore else { return "Начать считывание" }
        switch model.restoreSourceKind {
        case .file: return "Начать запись"
        case .url: return "Скачать и записать"
        case .drive: return "Начать клонирование"
        }
    }

    private var primaryActionIcon: String {
        guard model.operation == .restore else { return "arrow.down.doc.fill" }
        switch model.restoreSourceKind {
        case .file: return "arrow.down.to.line"
        case .url: return "icloud.and.arrow.down.fill"
        case .drive: return "externaldrive.fill.badge.plus"
        }
    }

    private func actionButton(
        title: String,
        icon: String,
        destructive: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let gradientColors: [Color]
        if destructive && model.isWorking {
            gradientColors = [danger.opacity(0.82), danger.opacity(0.62)]
        } else if destructive {
            gradientColors = [accentViolet, Color(red: 0.40, green: 0.28, blue: 0.82)]
        } else {
            gradientColors = [accentBlue, accentViolet]
        }

        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.custom("Avenir Next Demi Bold", size: 12))
            }
            .foregroundStyle(.white)
            .frame(width: 240, height: 40)
            .background(
                LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .shadow(color: (destructive ? accentViolet : accentBlue).opacity(disabled ? 0 : 0.22), radius: 18, y: 8)
            .opacity(disabled ? 0.34 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func statusSymbol(for phase: JobPhase) -> some View {
        let symbol: String
        let color: Color
        switch phase {
        case .completed:
            symbol = "checkmark.circle.fill"
            color = Color(red: 0.32, green: 0.79, blue: 0.61)
        case .failed:
            symbol = "xmark.octagon.fill"
            color = danger
        case .cancelled:
            symbol = "stop.circle.fill"
            color = warning
        default:
            symbol = "circle.dotted"
            color = accentBlue
        }
        return Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(color)
    }

    private func select(_ operation: OperationKind) {
        guard !model.isWorking, model.operation != operation else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            model.operation = operation
            model.imageURL = nil
            model.progress = nil
            model.errorMessage = nil
        }
    }

    private func formattedSize(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .decimal)
    }

    private func shortParentPath(_ url: URL) -> String {
        url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var primaryText: Color { Color(red: 0.91, green: 0.93, blue: 0.98) }
    private var secondaryText: Color { Color(red: 0.66, green: 0.71, blue: 0.79) }
    private var surface: Color { Color(red: 0.12, green: 0.15, blue: 0.20) }
    private var fieldSurface: Color { Color(red: 0.145, green: 0.18, blue: 0.24) }
    private var accentBlue: Color { Color(red: 0.28, green: 0.53, blue: 1.0) }
    private var accentViolet: Color { Color(red: 0.43, green: 0.37, blue: 0.98) }
    private var danger: Color { Color(red: 1.0, green: 0.38, blue: 0.44) }
    private var warning: Color { Color(red: 1.0, green: 0.67, blue: 0.32) }
}

private struct StepSection<Content: View>: View {
    let number: String
    let title: String
    let content: Content

    init(number: String, title: String, @ViewBuilder content: () -> Content) {
        self.number = number
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number)
                    .font(.custom("SF Mono", size: 9))
                    .foregroundStyle(Color(red: 0.35, green: 0.58, blue: 1.0))
                Text(title)
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(Color(red: 0.91, green: 0.93, blue: 0.98))
                Spacer()
            }
            content
        }
        .padding(11)
        .background(Color(red: 0.105, green: 0.132, blue: 0.18).opacity(0.96), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.065), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.16), radius: 12, y: 6)
    }
}

private struct GridBackdrop: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 42
            for x in stride(from: CGFloat.zero, through: size.width, by: spacing) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: CGFloat.zero, through: size.height, by: spacing) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(Color.white.opacity(0.018)), lineWidth: 1)
        }
        .mask(
            LinearGradient(
                colors: [Color.white.opacity(0.75), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }
}
