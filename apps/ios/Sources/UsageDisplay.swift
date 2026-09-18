enum ModelDisplay {
  /// The leaf Relay folds overflow into is the model `other`.
  static func name(_ model: String) -> String {
    model == "other" ? "Other" : model
  }
}
