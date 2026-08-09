import SwiftUI
import MacCleanerCore

/// AI 模型页：DeepSeek Key、模型、连接测试、隐私说明和缓存管理。
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
        VStack(spacing: 0) {
            pageHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI 模型")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("配置用于解释清理风险和进程影响的模型。模型只会在你主动发起 AI 分析时调用。")
                            .foregroundStyle(.secondary)
                    }

                    modelConfigurationCard

                    HStack(alignment: .top, spacing: 20) {
                        cacheCard
                        privacyCard
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var pageHeader: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
            }

            Spacer()

            Text("AI 模型")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            Color.clear
                .frame(width: 72, height: 1)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var modelConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型配置")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("仅支持 DeepSeek 的 OpenAI 兼容 API。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label("OpenAI 兼容协议", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }

            Divider()

            configurationField("提供商") {
                Label("深度求索 / DeepSeek", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.quaternary, lineWidth: 1)
                    }
            }

            configurationField("API Key") {
                SecureField("输入你的 API Key", text: $viewModel.apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    if viewModel.isConfigured {
                        Label("已配置；不显示已保存的 Key", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("尚未配置", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if viewModel.isConfigured {
                        Button("删除 Key", role: .destructive) {
                            showDeleteKeyConfirm = true
                        }
                        .controlSize(.small)
                    }
                }
                .font(.caption)
                Text("不会写入系统钥匙串；仅保存在这台 Mac 的应用偏好中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            configurationField("模型名称") {
                Picker("模型名称", selection: $viewModel.modelInput) {
                    ForEach(DeepSeekModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(.quaternary, lineWidth: 1)
                }
            }

            configurationField("接口地址") {
                TextField("https://api.deepseek.com", text: $viewModel.baseURLInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("默认地址为 https://api.deepseek.com；使用兼容网关时可改为对应的 HTTPS 地址。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("查看文档", destination: URL(string: "https://api-docs.deepseek.com/")!)
                        .font(.caption)
                }
            }

            advancedConfiguration

            if let message = viewModel.serviceConfigurationErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("保存配置") {
                    Task { await viewModel.saveModelConfiguration() }
                }
                .buttonStyle(.borderedProminent)

                Button("测试连接") {
                    Task { await viewModel.testConnection() }
                }
                .disabled(!viewModel.isConfigured || viewModel.connectionState == .testing)

                connectionStateView

                Spacer()
            }
        }
        .padding(24)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var advancedConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("高级配置")
                .font(.headline)

            HStack(spacing: 24) {
                Label("结构化工具调用", systemImage: "checkmark.square.fill")
                    .foregroundStyle(.primary)
                Label("思考模式已关闭", systemImage: "minus.square")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            Text("为保证清理建议可以校验，工具调用始终开启；当前模型调用会自动关闭思考模式。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("AI 缓存", systemImage: "internaldrive")
                .font(.headline)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("数据与隐私", systemImage: "hand.raised")
                .font(.headline)
            Text(Self.privacyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func configurationField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
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
