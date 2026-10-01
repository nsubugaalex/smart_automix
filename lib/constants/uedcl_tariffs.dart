/// UEDCL / ERA electricity tariff categories relevant to a small-scale
/// industrial customer in Uganda.
///
/// Uganda's retail electricity tariffs are set quarterly by the Electricity
/// Regulatory Authority (ERA) and billed through the distributor (UEDCL).
/// The rates below are placeholder defaults only — always confirm the
/// current published rate on your UEDCL bill or the ERA tariff schedule
/// before relying on the cost estimates in this app, and update them in
/// the Tariff screen when ERA issues a new quarterly adjustment.
enum UedclTariffCategory {
  domestic,
  commercial,
  smallIndustrial,
  mediumIndustrial,
}

extension UedclTariffCategoryX on UedclTariffCategory {
  String get label {
    switch (this) {
      case UedclTariffCategory.domestic:
        return 'Domestic';
      case UedclTariffCategory.commercial:
        return 'Commercial';
      case UedclTariffCategory.smallIndustrial:
        return 'Small Industrial (<= 100 kVA)';
      case UedclTariffCategory.mediumIndustrial:
        return 'Medium Industrial (> 100 kVA)';
    }
  }

  String get description {
    switch (this) {
      case UedclTariffCategory.domestic:
        return 'Households and small residential loads.';
      case UedclTariffCategory.commercial:
        return 'Shops, offices and small business premises.';
      case UedclTariffCategory.smallIndustrial:
        return 'Workshops, mills and small factories on a low-voltage '
            'industrial connection.';
      case UedclTariffCategory.mediumIndustrial:
        return 'Larger industrial customers, typically metered at 11kV.';
    }
  }

  /// Placeholder default rate in UGX per kWh. NOT an authoritative figure —
  /// replace with the rate on your current UEDCL bill in the Tariff screen.
  double get defaultRatePerKwh {
    switch (this) {
      case UedclTariffCategory.domestic:
        return 250.0;
      case UedclTariffCategory.commercial:
        return 650.0;
      case UedclTariffCategory.smallIndustrial:
        return 550.0;
      case UedclTariffCategory.mediumIndustrial:
        return 450.0;
    }
  }

  static UedclTariffCategory fromName(String name) {
    return UedclTariffCategory.values.firstWhere(
      (c) => c.name == name,
      orElse: () => UedclTariffCategory.smallIndustrial,
    );
  }
}
