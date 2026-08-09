import SwiftUI
import MacCleanerCore

/// AI 设置页：DeepSeek Key、连接测试、隐私说明和缓存管理。
/// Key 写入本机应用偏好，不回显完整内容。
struct AISettingsView: View {
    @Bindable var viewModel: AISettingsViewModel
    let onBack: (() -> Void)?

    @State private var showDeleteKeyConfirm = false
    @State private var showClearCacheConfirm = false

    init(viewModel: AISettingsViewModel, onBack: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onBack = onBack
    }

    var body: some View {
        Form {
            Section("DeepSeek API Key") {
                HStack {
                    if viewModel.isConfigured {
                        Label("已配置", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("未配置", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.isConfigured {
                        Button("删除 Key", role: .destructive) {
                            showDeleteKeyConfirm = true
                        }
                    }
                }

                SecureField("输入 API Key（保存在本机应用设置）", text: $viewModel.apiKeyInput)
                    .textFieldStyle(.roundedBorder)

                Text("不会写入系统钥匙串；仅保存在这台 Mac 的应用偏好中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("保存") {
                        Task { await viewModel.saveKey() }
                    }
                    .disabled(viewModel.apiKeyInput.isEmpty)

                    Button("测试连接") {
                        Task { await viewModel.testConnection() }
                    }
                    .disabled(!viewModel.isConfigured || viewModel.connectionState == .testing)

                    connectionStateView
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("服务信息") {
                Picker("模型", selection: $viewModel.modelInput) {
                    ForEach(DeepSeekModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                .pickerStyle(.menu)
                TextField("Base URL", text: $viewModel.baseURLInput)
                    .textFieldStyle(.roundedBorder)
                Text("默认地址为 https://api.deepseek.com；使用兼容服务时可改为对应的 HTTPS 地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("保存服务配置") {
                    viewModel.saveServiceConfiguration()
                }
                if let message = viewModel.serviceConfigurationErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("AI 缓存") {
                if let stats = viewModel.cacheStats {
                    LabeledContent("缓存条数", value: "\(stats.recordCount)")
                    LabeledContent("缓存占用", value: SizeFormatter.format(bytes: Int64(stats.byteCount)))
                } else {
                    Text("暂无缓存统计")
                        .foregroundStyle(.secondary)
                }
                Button("清空缓存", role: .destructive) {
                    showClearCacheConfirm = true
                }
            }

            Section("发送数据范围") {
                Text(Self.privacyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let onBack {
                VStack(spacing: 0) {
                    HStack {
                        Button(action: onBack) {
                            Label("返回", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Text("AI 设置")
                            .font(.title2)
                            .fontWeight(.bold)

                        Spacer()

                        Color.clear
                            .frame(width: 72, height: 1)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)

                    Divider()
                }
            }
        }
        .task { await viewModel.load() }
        .alert("确认发送数据范围", isPresented: $viewModel.presentPrivacyConsent) {
            Button("取消", role: .cancel) {
                viewModel.cancelPrivacyConsent()
            }
            Button("同意并保存") {
                Task { await viewModel.acceptPrivacyConsentAndSave() }
            }
        } message: {
            Text(Self.privacyText)
        }
        .alert("删除 API Key？", isPresented: $showDeleteKeyConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await viewModel.deleteKey() }
            }
        } message: {
            Text("删除后需要重新输入才能使用 AI 分析。已有的本地 AI 缓存不受影响。")
        }
        .alert("清空 AI 缓存？", isPresented: $showClearCacheConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task { await viewModel.clearCache() }
            }
        } message: {
            Text("清空后再次分析需要重新请求 DeepSeek。API Key 不受影响。")
        }
    }

    @ViewBuilder
    private var connectionStateView: some View {
        switch viewModel.connectionState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .success:
            Label("连接成功", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// 隐私说明正文（版本 1）。说明变化时递增 consent version 重新提示。
    static let privacyText = """
    AI 分析会把所选清理项的完整路径、大小、时间、类型和来源标签，或所选进程的 PID、可执行路径、用户、CPU、内存、运行时长与签名状态发送给 DeepSeek。不会发送文件内容、环境变量或完整命令行。AI 只提供解释、风险评级和建议，不会自动选择、删除或结束进程。
    """
}
