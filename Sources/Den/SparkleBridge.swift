import AppKit
import DenHost
import Sparkle

/// Sparkle behind den's `updates` service: no Sparkle windows. Every stage is an
/// `updates.sparkle` event, and the `updates` plugin answers with `updates.sparkleReply`
/// (it shows the toast and decides when to install).
@MainActor
final class DenSparkle: NSObject, SparkleBridge, SPUUserDriver, SPUUpdaterDelegate {
  let service: UpdatesService
  /// Called right before Sparkle quits den to install, so the quit skips the quit dialog.
  var willInstall: () -> Void = {}
  var channel = "stable"
  var updater: SPUUpdater?
  var pending: ((SPUUserUpdateChoice) -> Void)?

  init(service: UpdatesService) { self.service = service }

  func configure(channel: String) {
    self.channel = channel
    guard updater == nil else { return }
    let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
    u.automaticallyChecksForUpdates = false  // the plugin schedules checks
    u.automaticallyDownloadsUpdates = false
    do { try u.start() } catch { service.sparkleEvent("error", error: error.localizedDescription) }
    updater = u
  }

  func check(userInitiated: Bool) {
    if updater == nil { configure(channel: channel) }
    guard let updater else { return }
    if userInitiated { updater.checkForUpdates() } else { updater.checkForUpdatesInBackground() }
  }

  func reply(_ choice: String) {
    guard let r = pending else { return }
    pending = nil
    switch choice {
    case "install": r(.install)
    case "skip": r(.skip)
    default: r(.dismiss)
    }
  }

  // MARK: SPUUpdaterDelegate

  nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    MainActor.assumeIsolated { channel == "prerelease" ? ["prerelease"] : [] }
  }

  nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    MainActor.assumeIsolated { willInstall() }
  }

  // MARK: SPUUserDriver

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { service.sparkleEvent("checking") }

  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    pending = reply
    // Already downloaded earlier (resumed): straight to "ready".
    service.sparkleEvent(state.stage == .installing ? "ready" : "found", version: appcastItem.displayVersionString)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    service.sparkleEvent("none")
    acknowledgement()
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    service.sparkleEvent("error", error: error.localizedDescription)
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) { service.sparkleEvent("downloading") }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
  func showDownloadDidReceiveData(ofLength length: UInt64) {}
  func showDownloadDidStartExtractingUpdate() {}
  func showExtractionReceivedProgress(_ progress: Double) {}

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    pending = reply
    service.sparkleEvent("ready")
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    willInstall()
    service.sparkleEvent("installing")
    if !applicationTerminated { retryTerminatingApplication() }
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
  func showUpdateInFocus() {}
  func dismissUpdateInstallation() {}
}
