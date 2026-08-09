import Testing
@testable import DevClean

@Suite("Home tool cards")
struct HomeToolCardTests {
    @Test("首页功能区包含 AI 设置卡片")
    func includesAISettingsCard() {
        let card = try! #require(HomeToolCard.standard.first { $0.destination == .aiSettings })

        #expect(card.title == "AI 设置")
        #expect(card.subtitle == "配置模型与 API Key")
    }
}
