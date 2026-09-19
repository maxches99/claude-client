import Foundation

/// The system CSPRNG (arc4random on Darwin, getrandom on Linux) for tokens and room ids.
enum SecureRandom {
    static var generator = SystemRandomNumberGenerator()
}
