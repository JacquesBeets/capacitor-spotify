import Foundation
import SpotifyiOS
import UIKit

/// Minimal `SPTAppRemoteImageRepresentable` so `getImage` can fetch by raw
/// image identifier without holding a full track object.
private final class ImageItem: NSObject, SPTAppRemoteImageRepresentable {
    let imageIdentifier: String
    init(_ imageIdentifier: String) {
        self.imageIdentifier = imageIdentifier
    }
}

/// Playback commands, all of them thin wrappers over `SPTAppRemotePlayerAPI`.
///
/// Split out of `SpotifyRemoteManager` so the connection lifecycle and the
/// command surface stay readable independently.
extension SpotifyRemoteManager {
    // MARK: - Playback

    func play(uri: String?, completion: @escaping VoidCompletion) {
        guard let player = requirePlayer(completion) else { return }
        guard let uri = uri, !uri.isEmpty else {
            player.resume(playbackCallback(completion))
            return
        }
        player.play(uri, callback: playbackCallback(completion))
    }

    func resume(completion: @escaping VoidCompletion) {
        requirePlayer(completion)?.resume(playbackCallback(completion))
    }

    func pause(completion: @escaping VoidCompletion) {
        requirePlayer(completion)?.pause(playbackCallback(completion))
    }

    func togglePlay(completion: @escaping VoidCompletion) {
        guard let player = requirePlayer(completion) else { return }
        player.getPlayerState { [weak self] result, error in
            guard let self = self else { return }
            guard let state = result as? (any SPTAppRemotePlayerState), error == nil else {
                completion(.failure(SpotifyError.from(error, fallback: .playbackFailed, prefix: "Could not read player state")))
                return
            }
            if state.isPaused {
                player.resume(self.playbackCallback(completion))
            } else {
                player.pause(self.playbackCallback(completion))
            }
        }
    }

    func skipNext(completion: @escaping VoidCompletion) {
        requirePlayer(completion)?.skip(toNext: playbackCallback(completion))
    }

    func skipPrevious(completion: @escaping VoidCompletion) {
        requirePlayer(completion)?.skip(toPrevious: playbackCallback(completion))
    }

    func seek(toPositionMs positionMs: Int, completion: @escaping VoidCompletion) {
        requirePlayer(completion)?.seek(toPosition: positionMs, callback: playbackCallback(completion))
    }

    func setShuffle(_ enabled: Bool, completion: @escaping VoidCompletion) {
        requirePlayer(completion)?.setShuffle(enabled, callback: playbackCallback(completion))
    }

    func setRepeatMode(_ mode: SPTAppRemotePlaybackOptionsRepeatMode, completion: @escaping VoidCompletion) {
        requirePlayer(completion)?.setRepeatMode(mode, callback: playbackCallback(completion))
    }

    func getPlayerState(completion: @escaping StateCompletion) {
        guard appRemote.isConnected, let player = appRemote.playerAPI else {
            completion(.failure(SpotifyError(.notConnected, "Not connected to the Spotify app — call connect() first")))
            return
        }
        player.getPlayerState { result, error in
            guard let state = result as? (any SPTAppRemotePlayerState), error == nil else {
                completion(.failure(SpotifyError.from(error, fallback: .playbackFailed, prefix: "Could not read player state")))
                return
            }
            completion(.success(playerStateToJS(state)))
        }
    }

    func getImage(imageId: String, widthPx: Int, completion: @escaping StateCompletion) {
        guard appRemote.isConnected, let images = appRemote.imageAPI else {
            completion(.failure(SpotifyError(.notConnected, "Not connected to the Spotify app — call connect() first")))
            return
        }
        let size = CGSize(width: widthPx, height: widthPx)
        images.fetchImage(forItem: ImageItem(imageId), with: size) { result, error in
            guard let image = result as? UIImage, error == nil else {
                completion(.failure(SpotifyError.from(error, fallback: .playbackFailed, prefix: "Could not fetch image")))
                return
            }
            guard let data = image.pngData() else {
                completion(.failure(SpotifyError(.unknown, "Could not encode the fetched image as PNG")))
                return
            }
            completion(.success(["dataUrl": "data:image/png;base64,\(data.base64EncodedString())"]))
        }
    }

    // MARK: - Helpers

    private func requirePlayer(_ completion: @escaping VoidCompletion) -> (any SPTAppRemotePlayerAPI)? {
        guard appRemote.isConnected, let player = appRemote.playerAPI else {
            completion(.failure(SpotifyError(.notConnected, "Not connected to the Spotify app — call connect() first")))
            return nil
        }
        return player
    }

    private func playbackCallback(_ completion: @escaping VoidCompletion) -> SPTAppRemoteCallback {
        { _, error in
            if let error = error {
                completion(.failure(SpotifyError.from(error, fallback: .playbackFailed, prefix: "Playback command failed")))
            } else {
                completion(.success(()))
            }
        }
    }
}
