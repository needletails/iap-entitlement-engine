//
//  File.swift
//  
//
//  Created by Cole M on 5/30/23.
//

import Foundation

enum DateFormats: String {
    /*
     EXAMPLES OF DATE FORMATS
     Friday, Nov 27, 2020             --------- EEEE, MMM d, yyyy
     11/27/2020                       --------- MM/dd/yyyy
     11-27-2020 02:13                 --------- MM-dd-yyyy HH:mm
     Nov 27, 2:13 AM                  --------- MMM d, h:mm a
     November 2020                    --------- MMMM yyyy
     Nov 27, 2020                     --------- MMM d, yyyy
     Fri, 27 Nov 2020 02:13:28 +0000  --------- E, d MMM yyyy HH:mm:ss Z
     2020-11-27T02:13:28+0000         --------- yyyy-MM-dd'T'HH:mm:ssZ
     27.11.20                         --------- dd.MM.yy
     02:13:28.555                     --------- HH:mm:ss.SSS
     */
    
    case first = "EEEE, MMM d, yyyy"
    case second = "MM/dd/yyyy"
    case third = "MM-dd-yyyy HH:mm"
    case fourth = "MMM d, h:mm a"
    case fifth = "MMMM yyyy"
    case sixth = "MMM d, yyyy"
    case seventh = "E, d MMM yyyy HH:mm:ss Z"
    case eighth = "yyyy-MM-dd'T'HH:mm:ssZ"
    case ninth = "dd.MM.yy"
    case tenth = "HH:mm:ss.SSS"
}
