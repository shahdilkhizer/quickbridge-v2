public with sharing class QuickbridgeMappingFacade {
  public class MappingSuggestion {
    @AuraEnabled public String workspaceKey;
    @AuraEnabled public String salesforceField;
    @AuraEnabled public String externalPath;
    @AuraEnabled public String confidence;
  }

  public class MappingAnalysis {
    @AuraEnabled public Integer healthScore;
    @AuraEnabled public Integer totalMappings;
    @AuraEnabled public Integer requiredMappings;
    @AuraEnabled public Integer missingRequired;
    @AuraEnabled public List<String> warnings = new List<String>();
    @AuraEnabled public List<MappingSuggestion> suggestions = new List<MappingSuggestion>();
  }

  @AuraEnabled(cacheable=false)
  public static QuickbridgeMappingController.MappingWorkspace getMappingWorkspace(String sessionToken, String connectorKey) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    return QuickbridgeMappingController.getMappingWorkspace(connectorKey);
  }

  @AuraEnabled
  public static QuickbridgeMappingController.SaveResponse saveMappings(String sessionToken, String requestJson) {
    QuickbridgeAdminSecurity.requireManage();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    QuickbridgeMappingController.SaveResponse response = QuickbridgeMappingController.saveMappings(requestJson);
    QuickbridgeAdminSecurity.audit('MAPPING_SAVE', connectorFromRequest(requestJson), response.status, null, null);
    return response;
  }

  @AuraEnabled
  public static QuickbridgeMappingController.SaveResponse clearMappings(
    String sessionToken,
    String connectorKey,
    String operationKey,
    String salesforceObject,
    String externalObject,
    String direction
  ) {
    QuickbridgeAdminSecurity.requireManage();
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    QuickbridgeMappingController.SaveResponse response = QuickbridgeMappingController.clearMappings(
      connectorKey, operationKey, salesforceObject, externalObject, direction
    );
    QuickbridgeAdminSecurity.audit('MAPPING_RESET', connectorKey, response.status, operationKey, null);
    return response;
  }

  @AuraEnabled(cacheable=false)
  public static QuickbridgeMappingController.DeploymentStatus getDeploymentStatus(String sessionToken, String deploymentId) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    return QuickbridgeMappingController.getDeploymentStatus(deploymentId);
  }

  @AuraEnabled(cacheable=false)
  public static MappingAnalysis analyzeMappings(String sessionToken, String requestJson) {
    QuickbridgeAdminSecurity.requireSession(sessionToken);
    String connectorKey = connectorFromRequest(requestJson);
    QuickbridgeMappingController.MappingWorkspace workspace = QuickbridgeMappingController.getMappingWorkspace(connectorKey);
    MappingAnalysis result = new MappingAnalysis();
    result.totalMappings = 0;
    result.requiredMappings = 0;
    result.missingRequired = 0;
    for (QuickbridgeMappingController.OperationWorkspace operation : workspace.operations) {
      Set<String> mappedFields = new Set<String>();
      Map<String, String> externalByNormalizedName = new Map<String, String>();
      for (QuickbridgeMappingController.SelectOption optionValue : operation.externalFields) {
        externalByNormalizedName.put(normalizedName(optionValue.value), optionValue.value);
      }
      for (QuickbridgeMappingController.MappingRow row : operation.mappings) {
        result.totalMappings++;
        if (row.required == true) {
          result.requiredMappings++;
          if (String.isBlank(row.externalPath)) result.missingRequired++;
        }
        if (String.isNotBlank(row.salesforceField)) mappedFields.add(row.salesforceField.toLowerCase());
      }
      for (QuickbridgeMappingController.SelectOption salesforceField : operation.salesforceFields) {
        String normalizedField = normalizedName(salesforceField.value);
        if (mappedFields.contains(salesforceField.value.toLowerCase()) || !externalByNormalizedName.containsKey(normalizedField)) continue;
        MappingSuggestion suggestion = new MappingSuggestion();
        suggestion.workspaceKey = operation.workspaceKey;
        suggestion.salesforceField = salesforceField.value;
        suggestion.externalPath = externalByNormalizedName.get(normalizedField);
        suggestion.confidence = 'High';
        result.suggestions.add(suggestion);
      }
    }
    result.healthScore = result.totalMappings == 0
      ? 0
      : Math.max(0, Math.round(((Decimal)(result.totalMappings - result.missingRequired) * 100) / result.totalMappings));
    if (result.missingRequired > 0) result.warnings.add(result.missingRequired + ' required mappings are incomplete.');
    if (workspace.operations.isEmpty()) result.warnings.add('No implemented operations are available for this connector.');
    return result;
  }

  @AuraEnabled
  public static QuickbridgeMappingController.SaveResponse applyMappingSuggestions(String sessionToken, String requestJson) {
    return saveMappings(sessionToken, requestJson);
  }

  private static String connectorFromRequest(String requestJson) {
    try {
      Map<String, Object> request = (Map<String, Object>)JSON.deserializeUntyped(requestJson);
      String connectorKey = request == null ? null : String.valueOf(request.get('connectorKey'));
      if (String.isBlank(connectorKey) || !Pattern.matches('^[A-Za-z0-9_-]{1,80}$', connectorKey)) handled('Mapping request is invalid.');
      return connectorKey.trim().toLowerCase();
    } catch (Exception error) {
      handled('Mapping request is invalid.');
      return null;
    }
  }

  private static String normalizedName(String value) {
    return String.valueOf(value).toLowerCase().replaceAll('[^a-z0-9]', '');
  }

  private static void handled(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    throw error;
  }
}