import Foundation
import UIKit

// MARK: - Exercise Definition (loaded from JSON)

struct ExerciseDefinition: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    let instructions: String?
    let imageName: String?
    let videoName: String?
    let equipmentId: String?
    let bodyPartId: String?
    let exerciseType: String?
    let targetMusclesId: String?
    let synergistMusclesId: String?
    let videoFile: String?
    let localizedNames: [String: String?]?

    // Set for exercises from my_exercises.json (not decoded from the Lyfta library)
    var aliases: [String] = []
    var category: String?
    var isMine = false
    var isCurated = false
    var localMedia: String?
    var hasLocalVideo = false

    enum CodingKeys: String, CodingKey {
        case id, name, instructions
        case imageName = "image_name"
        case videoName = "video_name"
        case equipmentId = "equipment_id"
        case bodyPartId = "body_part_id"
        case exerciseType = "exercise_type"
        case targetMusclesId = "Target_muscles_id"
        case synergistMusclesId = "Synergist_muscles_id"
        case videoFile = "video_file"
        case localizedNames = "localized_names"
    }

    var imageURL: URL? {
        if let localMedia, let url = Bundle.main.url(forResource: localMedia, withExtension: "png", subdirectory: "ExerciseMedia") {
            return url
        }
        guard let s = imageName, s.hasPrefix("http") else { return nil }
        return URL(string: s)
    }

    var videoURL: URL? {
        if hasLocalVideo, let localMedia, let url = Bundle.main.url(forResource: localMedia, withExtension: "mp4", subdirectory: "ExerciseMedia") {
            return url
        }
        guard let s = videoFile, s.hasPrefix("http") else { return nil }
        return URL(string: s)
    }

    var targetMuscleIds: [Int] { parseIds(targetMusclesId) }
    var synergistMuscleIds: [Int] { parseIds(synergistMusclesId) }
    var equipmentIds: [Int] { parseIds(equipmentId) }
    var bodyPartIds: [Int] { parseIds(bodyPartId) }

    var targetMuscles: [MuscleInfo] { targetMuscleIds.compactMap { MuscleInfo.from(id: $0) } }
    var synergistMuscles: [MuscleInfo] { synergistMuscleIds.compactMap { MuscleInfo.from(id: $0) } }
    var equipment: [EquipmentInfo] { equipmentIds.compactMap { EquipmentInfo.from(id: $0) } }
    var bodyParts: [BodyPartInfo] { bodyPartIds.compactMap { BodyPartInfo.from(id: $0) } }

    var allMuscleIds: Set<Int> {
        Set(targetMuscleIds + synergistMuscleIds)
    }

    private func parseIds(_ str: String?) -> [Int] {
        guard let str else { return [] }
        let cleaned = str.replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return cleaned.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - Muscle Info

struct MuscleInfo: Identifiable, Hashable {
    let id: Int
    let name: String
    let frontImages: [String]
    let backImages: [String]

    static func from(id: Int) -> MuscleInfo? {
        allMuscles.first { $0.id == id }
    }

    static let allMuscles: [MuscleInfo] = [
        MuscleInfo(id: 2, name: "Adductor Longus", frontImages: ["front_hip_adductors"], backImages: []),
        MuscleInfo(id: 3, name: "Adductor Magnus", frontImages: [], backImages: ["back_hip_adductors"]),
        MuscleInfo(id: 4, name: "Biceps", frontImages: ["front_biceps"], backImages: ["back_biceps"]),
        MuscleInfo(id: 5, name: "Brachialis", frontImages: ["front_brachialis"], backImages: ["back_brachialis"]),
        MuscleInfo(id: 6, name: "Brachioradialis", frontImages: ["front_brachioradialis"], backImages: []),
        MuscleInfo(id: 7, name: "Deep Hip Rotators", frontImages: [], backImages: []),
        MuscleInfo(id: 8, name: "Front Delts", frontImages: ["front_deltoid_anterior"], backImages: []),
        MuscleInfo(id: 9, name: "Side Delts", frontImages: ["front_deltoid_lateral"], backImages: []),
        MuscleInfo(id: 10, name: "Rear Delts", frontImages: [], backImages: ["back_deltoids"]),
        MuscleInfo(id: 11, name: "Erector Spinae", frontImages: [], backImages: ["back_erector_spinae"]),
        MuscleInfo(id: 12, name: "Gastrocnemius", frontImages: ["front_gastrocnemius"], backImages: ["back_gastrocnemius"]),
        MuscleInfo(id: 13, name: "Glute Max", frontImages: [], backImages: ["back_gluteus_maximus"]),
        MuscleInfo(id: 14, name: "Glute Med", frontImages: [], backImages: ["back_gluteus_medius"]),
        MuscleInfo(id: 15, name: "Glute Min", frontImages: [], backImages: []),
        MuscleInfo(id: 16, name: "Gracilis", frontImages: [], backImages: ["back_hip_adductors"]),
        MuscleInfo(id: 17, name: "Hamstrings", frontImages: [], backImages: ["back_hamstrings"]),
        MuscleInfo(id: 18, name: "Iliopsoas", frontImages: ["front_iliopsoas"], backImages: []),
        MuscleInfo(id: 19, name: "Infraspinatus", frontImages: [], backImages: ["back_infraspinatus"]),
        MuscleInfo(id: 20, name: "Lats", frontImages: [], backImages: ["back_latissimus_dorsi"]),
        MuscleInfo(id: 21, name: "Levator Scapulae", frontImages: [], backImages: ["back_neck"]),
        MuscleInfo(id: 22, name: "Obliques", frontImages: ["front_oliques"], backImages: ["back_obliques"]),
        MuscleInfo(id: 23, name: "Pectineous", frontImages: ["front_hip_adductors"], backImages: []),
        MuscleInfo(id: 24, name: "Upper Chest", frontImages: ["front_chest", "front_chest_clavicular_head"], backImages: []),
        MuscleInfo(id: 25, name: "Chest", frontImages: ["front_chest", "front_chest_sternal_head"], backImages: []),
        MuscleInfo(id: 26, name: "Popliteus", frontImages: [], backImages: ["back_popliteus"]),
        MuscleInfo(id: 27, name: "Quads", frontImages: ["front_quadriceps"], backImages: ["back_quadriceps"]),
        MuscleInfo(id: 28, name: "Abs", frontImages: ["front_rectus_abdominis"], backImages: []),
        MuscleInfo(id: 29, name: "Sartorius", frontImages: ["front_sartorius"], backImages: []),
        MuscleInfo(id: 30, name: "Serratus Ante", frontImages: [], backImages: []),
        MuscleInfo(id: 31, name: "Serratus Anterior", frontImages: ["front_serratus_anterior"], backImages: []),
        MuscleInfo(id: 32, name: "Soleus", frontImages: ["front_soleus"], backImages: ["back_soleus"]),
        MuscleInfo(id: 33, name: "Splenius", frontImages: [], backImages: ["back_neck"]),
        MuscleInfo(id: 34, name: "Neck", frontImages: ["front_neck"], backImages: []),
        MuscleInfo(id: 35, name: "Subscapularis", frontImages: [], backImages: []),
        MuscleInfo(id: 36, name: "Tensor Fasciae Latae", frontImages: ["front_tensor_fasciae_femoris"], backImages: []),
        MuscleInfo(id: 37, name: "Teres Major", frontImages: [], backImages: ["back_teres_major"]),
        MuscleInfo(id: 38, name: "Teres Minor", frontImages: [], backImages: ["back_teres_minor"]),
        MuscleInfo(id: 39, name: "Tibialis Anterior", frontImages: ["front_tibias"], backImages: []),
        MuscleInfo(id: 40, name: "Transverse Abs", frontImages: ["front_rectus_abdominis"], backImages: []),
        MuscleInfo(id: 41, name: "Lower Traps", frontImages: [], backImages: ["back_lower_trapezius"]),
        MuscleInfo(id: 42, name: "Mid Traps", frontImages: [], backImages: ["back_middle_trapezius", "back_lower_trapezius"]),
        MuscleInfo(id: 43, name: "Upper Traps", frontImages: ["front_trapezius"], backImages: ["back_upper_trapezius"]),
        MuscleInfo(id: 44, name: "Triceps", frontImages: ["front_triceps"], backImages: ["back_triceps"]),
        MuscleInfo(id: 45, name: "Wrist Extensors", frontImages: ["front_wrist_extensors"], backImages: []),
        MuscleInfo(id: 46, name: "Wrist Flexors", frontImages: [], backImages: ["back_wrist_flexors"]),
    ]
}

// MARK: - Body Part Info

struct BodyPartInfo: Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String

    static func from(id: Int) -> BodyPartInfo? {
        allBodyParts.first { $0.id == id }
    }

    static let allBodyParts: [BodyPartInfo] = [
        BodyPartInfo(id: 2, name: "Chest", icon: "figure.strengthtraining.traditional"),
        BodyPartInfo(id: 3, name: "Hips", icon: "figure.walk"),
        BodyPartInfo(id: 4, name: "Back", icon: "figure.rowing"),
        BodyPartInfo(id: 5, name: "Upper Arms", icon: "figure.boxing"),
        BodyPartInfo(id: 6, name: "Shoulders", icon: "figure.arms.open"),
        BodyPartInfo(id: 7, name: "Forearms", icon: "hand.raised.fill"),
        BodyPartInfo(id: 8, name: "Calves", icon: "figure.walk"),
        BodyPartInfo(id: 9, name: "Neck", icon: "person.fill"),
        BodyPartInfo(id: 10, name: "Cardio", icon: "heart.fill"),
        BodyPartInfo(id: 11, name: "Full Body", icon: "figure.mixed.cardio"),
        BodyPartInfo(id: 12, name: "Abs", icon: "figure.core.training"),
        BodyPartInfo(id: 13, name: "Plyometrics", icon: "figure.jumprope"),
        BodyPartInfo(id: 14, name: "Weightlifting", icon: "figure.strengthtraining.traditional"),
        BodyPartInfo(id: 15, name: "Yoga", icon: "figure.yoga"),
        BodyPartInfo(id: 16, name: "Stretching", icon: "figure.flexibility"),
        BodyPartInfo(id: 17, name: "Biceps", icon: "figure.boxing"),
        BodyPartInfo(id: 18, name: "Triceps", icon: "figure.boxing"),
        BodyPartInfo(id: 19, name: "Quadriceps", icon: "figure.walk"),
        BodyPartInfo(id: 20, name: "Hamstrings", icon: "figure.walk"),
    ]
}

// MARK: - Equipment Info

struct EquipmentInfo: Identifiable, Hashable {
    let id: Int
    let name: String

    static func from(id: Int) -> EquipmentInfo? {
        allEquipment.first { $0.id == id }
    }

    static let allEquipment: [EquipmentInfo] = [
        EquipmentInfo(id: 1, name: "Barbell"),
        EquipmentInfo(id: 2, name: "Body Weight"),
        EquipmentInfo(id: 3, name: "Cable"),
        EquipmentInfo(id: 4, name: "Dumbbell"),
        EquipmentInfo(id: 5, name: "EZ Barbell"),
        EquipmentInfo(id: 6, name: "Leverage Machine"),
        EquipmentInfo(id: 7, name: "Sled Machine"),
        EquipmentInfo(id: 8, name: "Smith Machine"),
        EquipmentInfo(id: 9, name: "Weighted"),
        EquipmentInfo(id: 11, name: "Band"),
        EquipmentInfo(id: 12, name: "Battling Rope"),
        EquipmentInfo(id: 13, name: "Bosu Ball"),
        EquipmentInfo(id: 15, name: "Kettlebell"),
        EquipmentInfo(id: 16, name: "Medicine Ball"),
        EquipmentInfo(id: 18, name: "Power Sled"),
        EquipmentInfo(id: 19, name: "Resistance Band"),
        EquipmentInfo(id: 20, name: "Roll"),
        EquipmentInfo(id: 21, name: "Rollball"),
        EquipmentInfo(id: 22, name: "Rope"),
        EquipmentInfo(id: 23, name: "Stability Ball"),
        EquipmentInfo(id: 25, name: "Suspension"),
        EquipmentInfo(id: 26, name: "Trap Bar"),
        EquipmentInfo(id: 28, name: "Wheel Roller"),
    ]
}

// MARK: - Muscle Image Loading

enum MuscleImageLoader {
    static func loadOverlay(named name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp", subdirectory: "MuscleImages") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
