public with sharing class MappingFieldEligibilityService {
    private static final Set<String> BLOCKED = new Set<String>{
        'ownerid', 'createddate', 'createdbyid',
        'lastmodifieddate', 'lastmodifiedbyid', 'systemmodstamp',
        'isdeleted', 'recordtypeid', 'currencyisocode',
        'lastvieweddate', 'lastreferenceddate'
    };

    public static Boolean isSalesforceFieldAllowed(String fieldApiName) {
        if (String.isBlank(fieldApiName)) return true;
        return !BLOCKED.contains(fieldApiName.toLowerCase());
    }

    public static void assertNoBlockedSalesforceFields(List<String> sfFieldNames) {
        if (sfFieldNames == null) return;
        for (String name : sfFieldNames) {
            if (String.isBlank(name)) continue;
            if (!isSalesforceFieldAllowed(name)) {
                String msg = 'Field "' + name + '" cannot be used in a mapping.';
                AuraHandledException e = new AuraHandledException(msg);
                e.setMessage(msg);
                throw e;
            }
        }
    }
}