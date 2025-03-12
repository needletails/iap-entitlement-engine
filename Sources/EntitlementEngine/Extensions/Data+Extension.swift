//
//  Data+Extension.swift
//  iap-entitlement-engine
//
//  Created by Cole M on 10/13/24.
//

import Foundation

extension Date {
    var millisecondsSince1970: Int64 {
        return Int64((self.timeIntervalSince1970 * 1000.0).rounded())
    }
    
    init(milliseconds: Int64) {
        self = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

extension DateFormatter {
    func getFormattedDate(currentFormat: String, newFormat: String, date: Date) -> String {
        let dateFormatter = self
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.locale = Locale.current
        
        dateFormatter.dateFormat = currentFormat
        let converToNewFormat = self
        converToNewFormat.dateFormat = newFormat
        
        return converToNewFormat.string(from: date)
    }
}
