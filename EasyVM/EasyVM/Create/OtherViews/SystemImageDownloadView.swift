//
//  SystemImageDownloadView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI


struct DownloadButtonView : View {
    let name: String
    let image: String
    
    @State private var borderColor: Color = .gray
    var body: some View {
        VStack {
            Image(systemName: image)
                .font(.system(size: 40))
                .frame(width:50,height: 50)
            Text(name)
        }
        .padding(.all, 5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(.gray, lineWidth: 1)
        )
        .onHover { hover in
            if hover {
                borderColor = .blue
            } else {
                borderColor = .gray
            }
        }
    }
}

struct SystemImageDownloadView: View {
    
    @Environment(\.presentationMode) var presentationMode
    
    enum ImageSource {
        case latest_avaliable, input_url
    }
    
    @State var downloadMethod: ImageSource = .latest_avaliable
    @State var downloadInputUrl: String = ""
    
    
    var body: some View {
        
        VStack {
            
            Picker("Image Source", selection: $downloadMethod) {
                Text("Latest Avaliable Image").tag(ImageSource.latest_avaliable)
                Text("Image URL Input Below").tag(ImageSource.input_url)
            }
            .pickerStyle(.menu)
            
            if downloadMethod == .input_url {
                HStack {
                    Text("Image URL:")
                    TextField("Image URL", text: $downloadInputUrl)
                        .lineLimit(4)
                        .textFieldStyle(.plain)
                }
            }
            
            Spacer()
            ProgressView(value: 250, total: 1000)
            
            HStack {
                Text("25% - 250MB / 1000GB")
                    .lineLimit(5)
                    .font(.caption)
            }
            
            Spacer()
            
            HStack {
                Spacer()
                DownloadButtonView(name: "Start Download", image: "icloud.and.arrow.down")
                    .onTapGesture {
                        
                    }
                Spacer()
            }
            
            HStack {
                
                Spacer()

                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("Cancel")
                }
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("Confirm")
                }
                
            }
        }
        .padding()
        .frame(width: 600, height:260)
    }
}

struct SystemImageDownloadView_Previews: PreviewProvider {
    static var previews: some View {
        SystemImageDownloadView()
    }
}
