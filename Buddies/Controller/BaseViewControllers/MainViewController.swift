// Copyright 2016-2017 Cisco Systems Inc
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit
import Cartography
import SparkSDK
import AVFoundation
import CallKit
import Alamofire

let MessageReceptionNotificaton = "MessageReceivedNotification"
let CallReceptionNotification = "CallReceptionNotification"
class MainViewController: UIViewController, UserOptionDelegate{
    
    // MARK: - UI variables
    private let optionViewWidth = Constants.Size.screenWidth/4*3
    private var maskView: UIView?
    
    public var userOptionView: UserOptionView?
    public var navVC : UINavigationController?
    private var currentOptionType: UserOptionType = .Buddies
    
    // Receive Notification Variables
    private var provider: CXProvider
    fileprivate var callers = [UUID: Contact]()
    public var callViewController: BuddiesCallViewController?
    
    fileprivate var incomingCalls  = [Call]()
    fileprivate var newCall : Call?  = nil
    fileprivate var newCallCallee: Contact? = nil
    
    
    // MARK: - Life circle
    init() {
        self.provider = CXProvider(configuration: MainViewController.providerConfiguration)
        super.init(nibName: nil, bundle: nil)
        self.provider.setDelegate(self, queue: nil)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let choosedVC = ContactViewController(mainViewController: self)
        self.navVC = UINavigationController(rootViewController: choosedVC)
        self.navVC?.navigationBar.updateAppearance();
        self.view.addSubview((navVC?.view)!)
        // MARK: remove after 
        self.registerPhone()
    }
    public func registerPhone(){
        if(User.CurrentUser.loginType != .None && !User.CurrentUser.phoneRegisterd){
            let acitivtyIndicator = KTActivityIndicator()
            acitivtyIndicator.show(title: "Connecting...", at: (self.navVC?.view)!, offset: 0, size: 156, allowUserInteraction: false)
            SparkSDK?.phone.register({ (_ error) in
                acitivtyIndicator.hide()
                if(error == nil){
                    User.CurrentUser.phoneRegisterd = true
                    (self.navVC?.topViewController as! BaseViewController).updateViewController()
                    self.registerOnComingCall()
                }else{
                    KTInputBox.alert(title: "Register To Could Fail")
                }
            })
        }
    }
    // MARK: - SparkSDK: user login/logout Implementation
    @objc public func userLogin(){
        let SparkAuthenticator = OAuthAuthenticator(clientId: Constants.ClientId, clientSecret: Constants.ClientSecret, scope: Constants.Scope, redirectUri: Constants.RedirectUrl)
        SparkSDK = Spark(authenticator: SparkAuthenticator)
        SparkAuthenticator.authorize(parentViewController: self) { success in
            if success {
                KTActivityIndicator.singleton.show(title: "Logging in")
                SparkSDK?.people.getMe { res in
                    KTActivityIndicator.singleton.hide()
                    if let person = res.result.data {
                        if(User.updateCurrenUser(person: person, loginType: .User)){
                            self.registerSparkWebhook(completionHandler: { (_ res) in })
                            self.userOptionView?.updateSubViews()
                            self.registerPhone()
                        }
                    }else if let error = res.result.error {
                        KTInputBox.alert(error: error)
                    }
                }
            }else {
                KTInputBox.alert(title: "Login failed")
            }
        }
    }
    
    @objc public func GuestLogin(){
        let guestLoginVC = GuestSettingViewController()
        guestLoginVC.signInSuccessBlock = {
            self.userOptionView?.updateSubViews()
            self.registerSparkWebhook(completionHandler: { (_ res) in })
            self.registerPhone()
        }
        let loginNavVC = UINavigationController(rootViewController: guestLoginVC)
        self.present(loginNavVC, animated: true) {}
    }
    
    
    @objc public func GuestSetting(){
        let guestLoginVC = GuestSettingViewController()
        let loginNavVC = UINavigationController(rootViewController: guestLoginVC)
        self.present(loginNavVC, animated: true) {}
    }
    
    @objc public func userLogOut(){
        User.CurrentUser.logout()
        self.userOptionView?.updateSubViews()
        (self.navVC?.topViewController as! BaseViewController).updateViewController()
    }
    
    // MARK: - SparkSDK: Webhook Create / Register notification info into web hook server
    func registerSparkWebhook(completionHandler: ((Bool) -> Void)?) {
        
        if  let voipToken = UserDefaults.standard.string(forKey: "com.cisco.spark-ios-sdk.Buddies.data.device_voip_token"),
            let msgToken = UserDefaults.standard.string(forKey: "com.cisco.spark-ios-sdk.Buddies.data.device_msg_token") {
            
            KTActivityIndicator.singleton.show(title: "Connecting....")
            
            
            let threahGroup = DispatchGroup()
            
            /*
             Check if MSG web hook is registered for user
             */
            DispatchQueue.global().async(group: threahGroup, execute: DispatchWorkItem(block: {
                if(!User.CurrentUser.webHookCreated){
                    SparkSDK?.webhooks.list(completionHandler: { (response: ServiceResponse<[Webhook]>) in
                        switch response.result {
                        case .success(let value):
                            for webhook in value{
                                if(webhook.resource == "messages"){
                                    User.CurrentUser.setWebHookCreated(webHookId: (webhook.id)!)
                                    return
                                }
                            }
                            self.createNewWebHook()
                            break
                        case .failure:
                            self.createNewWebHook()
                            break
                        }
                    })
                }
            }))
            
            /*
             Register notificaiton info into web hook server
             */
            DispatchQueue.global().async(group: threahGroup, execute: DispatchWorkItem(block: {
                if(!User.CurrentUser.registerdOnWebhookServer){
                    /*
                     register device notification info on webhook server
                     */
                    let webHookServiceParamater: Parameters = [
                        "email": User.CurrentUser.email,
                        "voipToken": voipToken,
                        "msgToken": msgToken,
                        "personId": User.CurrentUser.id
                    ]
                    Alamofire.request("https://ios-demo-pushnoti-server.herokuapp.com/register", method: .post, parameters: webHookServiceParamater, encoding: JSONEncoding.default).validate().response { res in
                        KTActivityIndicator.singleton.hide()
                        completionHandler?(true)
                        if(res.error == nil){
                            print("Webhookserver Register success")
                            User.CurrentUser.setRegisterdOnWebHookServer(registerd: true)
                        }
                    }
                }
            }))
            threahGroup.notify(queue: DispatchQueue.global(), execute: {
                DispatchQueue.main.async {
                    KTActivityIndicator.singleton.hide()
                }
            })
        }
        else {
            completionHandler?(false)
        }
    }
    
    func createNewWebHook(){
        /* create webhook for notification reception */
        let webHookName = User.CurrentUser.name + "-MSG-WebHook"
        let targetUrl = Constants.Webhook.redirectUrl
        //                    let filter = Constants.Webhook.filter
        /*
         Scope of notification, should one of resource below
         [all, calls, rooms, messages, memberships, callMemberships]
         */
        let resource = "messages"
        /*
         events of notification, should one of resource below
         [created, all, updated, deleted]
         */
        let event = "all"
        SparkSDK?.webhooks.create(name: webHookName, targetUrl: targetUrl, resource: resource, event: event, completionHandler: { (response: ServiceResponse<Webhook>) in
            switch response.result{
                
            case .success(let webhook):
                User.CurrentUser.setWebHookCreated(webHookId: (webhook.id)!)
                break
            case .failure(let error):
                print(error.localizedDescription)
                break
            }
            
        })
    }
    
    // MARK: - message/call receiption notification dealing code
    static var providerConfiguration: CXProviderConfiguration {
        let providerConfiguration = CXProviderConfiguration(localizedName: "Buddies")
        providerConfiguration.supportsVideo = false
        providerConfiguration.maximumCallsPerCallGroup = 1
        providerConfiguration.maximumCallGroups = 1
        providerConfiguration.supportedHandleTypes = [.generic, .phoneNumber, .emailAddress]
        return providerConfiguration
    }
    
    func receviMessageNotification(fromEmail: String){
        if User.CurrentUser.getSingleGroupWithContactEmail(email: fromEmail) != nil{
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: MessageReceptionNotificaton), object: ["from":fromEmail])
        }else if(User.CurrentUser.loginType == .User){
            SparkSDK?.people.list(email: EmailAddress.fromString(fromEmail), max: 1) {
                (response: ServiceResponse<[Person]>) in
                KTActivityIndicator.singleton.hide()
                switch response.result {
                case .success(let value):
                    for person in value{
                        if let tempContack = Contact(person: person){
                            User.CurrentUser.addNewContactAsGroup(contact: tempContack)
                            if let localGroup = User.CurrentUser.getSingleGroupWithContactId(contactId: tempContack.id){
                                localGroup.unReadedCount += 1
                            }
                            NotificationCenter.default.post(name: NSNotification.Name(rawValue: MessageReceptionNotificaton), object: ["from":fromEmail])
                        }
                    }
                    break
                case .failure:
                    break
                }
            }
        }else{
            return
        }
        
    }
    
    
    // MARK: - UI Implementation
    private func setUpMaskView(){
        if(self.maskView == nil){
            self.maskView = UIView(frame: CGRect.zero)
            self.maskView?.frame = self.view.frame
            self.maskView?.backgroundColor = UIColor.black
            self.maskView?.alpha = 0
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissUserOptionView))
            self.maskView?.addGestureRecognizer(tap)
        }
    }
    
    private func setUpUserOptionView(){
        if(self.userOptionView == nil){
            self.userOptionView = UserOptionView(frame: CGRect(x: -Constants.Size.screenWidth/4*3, y: 0, width: Constants.Size.screenWidth/4*3, height: Constants.Size.screenHeight))
            self.userOptionView?.delegate = self
        }
    }
    
    @objc public func slideInUserOptionView() {
        self.setUpMaskView()
        self.setUpUserOptionView()
        self.view.addSubview(self.userOptionView!)
        self.view.addSubview(self.maskView!)
        constrain(self.maskView!) { view in
            view.height == view.superview!.height;
            view.width == view.superview!.width;
        }
        UIView.animate(withDuration: 0.2) {
            self.userOptionView?.transform = CGAffineTransform(translationX: self.optionViewWidth, y: 0)
            self.maskView?.transform = CGAffineTransform(translationX: self.optionViewWidth, y: 0)
            self.maskView?.alpha = 0.4
            self.navVC?.view.transform = CGAffineTransform(translationX: self.optionViewWidth, y: 0)
        }
    }
    @objc public func dismissUserOptionView(){
        UIView.animate(withDuration: 0.2, animations: {
            self.userOptionView?.transform = CGAffineTransform(translationX:0, y: 0)
            self.maskView?.transform = CGAffineTransform(translationX: 0, y: 0)
            self.maskView?.alpha = 0
            self.navVC?.view.transform = CGAffineTransform(translationX: 0, y: 0)
        }) { (complete) in
            self.maskView?.removeFromSuperview()
            self.userOptionView?.removeFromSuperview()
        }
    }
    
    // MARK: - UserOptionView Delegate
    /*
     Receive ButtonClick action on slide-in user option view
     */
    func processUserAction(optionType: UserOptionType){
        switch optionType {
        case .UserLogin:
            self.userLogin()
            break
        case .GuestLogin:
            self.GuestLogin()
            break
        case .LogOut:
            self.userLogOut()
            break
        default:
            break
        }
        if(optionType == .Buddies || optionType == .Teams || optionType == .Rooms || optionType == .LogOut){
            if(currentOptionType == optionType || optionType == .LogOut ){
                self.dismissUserOptionView()
            }else{
                currentOptionType = optionType
                self.updateCurrentViewController(optionType: optionType)
            }
        }
    }
    
    func updateCurrentViewController(optionType: UserOptionType){
        
        var choosedVC: BaseViewController
        if(optionType == .Buddies){
            choosedVC = ContactViewController(mainViewController: self)
        }else if(optionType == .Rooms){
            choosedVC = RoomListViewController(mainViewController: self)
        }else if(optionType == .Teams){
            choosedVC = TeamListViewController(mainViewController: self)
        }else{
            choosedVC = ContactViewController(mainViewController: self)
        }
        if(self.navVC != nil){
            self.navVC?.viewControllers.removeAll()
            self.navVC?.view.removeFromSuperview()
        }
        self.navVC = UINavigationController(rootViewController: choosedVC)
        self.navVC?.navigationBar.updateAppearance();
        self.navVC?.view.transform = CGAffineTransform(translationX: self.optionViewWidth, y: 0)
        self.view.addSubview((navVC?.view)!)
        self.view.bringSubview(toFront: self.maskView!)
        self.dismissUserOptionView()
    }
    
    public func receiveIncomingCall(from: String) {
        self.fetchCalleeInfo(from: from)
    }
    public func fetchCalleeInfo(from: String){
        if let localContact = User.CurrentUser.getSingleGroupWithContactId(contactId: from){
            self.newCallCallee = localContact[0]!
            self.reportNewIncomingCall(newCall: self.newCall, from: self.newCallCallee)
        }else{
            SparkSDK?.people.get(personId: from) { res in
                if let person = res.result.data, let contact = Contact(person: person) {
                    self.newCallCallee = contact
                    self.reportNewIncomingCall(newCall: self.newCall, from: self.newCallCallee)
                }
            }
        }
    }
    
    public func registerOnComingCall(){
        if(User.CurrentUser.phoneRegisterd){
            SparkSDK?.phone.onIncoming = { call in
                self.incomingCalls.append(call)
                self.newCall = call
                self.receiveIncomingCall(from: (call.from?.personId)!)
            }
        }
    }
    
    func reportNewIncomingCall(newCall: Call?, from: Contact?){
        let update = CXCallUpdate()
        update.hasVideo = true
        if let call = newCall , let callee  = from{
            self.callers[call.uuid] = callee
            update.remoteHandle = CXHandle(type: .emailAddress, value: callee.name)
            if(self.callViewController?.currentCall?.status == .connected){
                DispatchQueue.global().async {
                    call.reject(completionHandler: { (_) in })
                }
            }else{
                self.provider.reportNewIncomingCall(with: call.uuid, update: update) { error in }

            }
            self.newCall = nil
            self.newCallCallee = nil
        }
    }
    
    // MARK: - other functions
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(),
                                           Unmanaged.passUnretained(self).toOpaque(),
                                           nil,
                                           nil)
    }
}

// MARK: - receive voip notification callkit extention
extension MainViewController: CXProviderDelegate {
    
    func providerDidReset(_ provider: CXProvider) {
        print("@@@@@@@@@@@@@@@@@: did reset")
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
         print("@@@@@@@@@@@@@@@@@: CXAnswerCallAction")
        let uuid = action.callUUID
        if let contact = self.callers[uuid], let call = self.incomingCalls.filter({$0.uuid.uuidString == uuid.uuidString}).first{
            if self.callViewController == nil {
                self.callViewController?.removeFromParentViewController()
                self.callViewController = nil
                self.callViewController = BuddiesCallViewController(callee: contact, uuid: uuid, callkit: provider)
            }
            if let presentedViewController = self.presentedViewController,presentedViewController != self.callViewController {
                if let presentedNavController = presentedViewController as? UINavigationController {
                    presentedNavController.topViewController?.present(self.callViewController!, animated: true) {
                        self.callViewController?.answerNewIncomingCall(call: call, callKitAction: action)
                    }
                }
                else {
                    self.present(self.callViewController!, animated: true) {
                        self.callViewController?.answerNewIncomingCall(call: call, callKitAction: action)
                    }
                }
            }
            else if let presentedViewController = self.presentedViewController,presentedViewController == self.callViewController {
                self.callViewController?.answerNewIncomingCall(call: call, callKitAction: action)
            }
            else {
                self.present(self.callViewController!, animated: true) {
                    self.callViewController?.answerNewIncomingCall(call: call, callKitAction: action)
                }
            }
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
          print("@@@@@@@@@@@@@@@@@: CXSetGroupCallAction")
    }
    public func provider(_ provider: CXProvider, execute transaction: CXTransaction) -> Bool {
         print("@@@@@@@@@@@@@@@@@: CXSetGroupCallAction")
        return false
    }
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
         print("@@@@@@@@@@@@@@@@@: didActivate")
        if let call = self.incomingCalls.filter({$0.uuid.uuidString == action.callUUID.uuidString}).first{
            if call.status == .connected {
                call.hangup() {
                    error in
                }
            }
            else {
                call.reject(completionHandler: { (_ error) in })
            }
        }
        action.fulfill()
    }      
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("@@@@@@@@@@@@@@@@@: didActivate")
        if let call = self.incomingCalls.filter({$0.status == .connected}).first {
            call.updateAudioSession()
        }
    }
    
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("@@@@@@@@@@@@@@@@@: didDeactivate")
    }
}

