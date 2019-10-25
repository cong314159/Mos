//
//  ScrollCore.swift
//  Mos
//  滚动事件截取与插值计算核心类
//  Created by Caldis on 2017/1/14.
//  Copyright © 2017年 Caldis. All rights reserved.
//

import Cocoa

class ScrollCore {
    
    // 单例
    static let shared = ScrollCore()
    init() { print("Class 'ScrollCore' is initialized") }
    
    // 鼠标事件轴
    let axis = ( Y: UInt32(1), X: UInt32(1), YX: UInt32(2), YXZ: UInt32(3) )
    // 滚动数据
    var scrollCurr   = ( y: 0.0, x: 0.0 )  // 当前滚动距离
    var scrollBuffer = ( y: 0.0, x: 0.0 )  // 滚动缓冲距离
    var scrollDelta  = ( y: 0.0, x: 0.0 )  // 滚动方向记录
    // 热键数据
    var toggleScroll = false
    var blockSmooth = false
    // 滚动数值滤波, 用于去除滚动的起始抖动
    var scrollFiller = ScrollFiller()
    // 事件发送器
    var scrollEventPoster: CVDisplayLink?
    // 拦截层
    var scrollEventInterceptor: InterceptorRef?
    var hotkeyEventInterceptor: InterceptorRef?
    var tapKeeperTimer: Timer?
    // 拦截掩码
    let scrollEventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let hotkeyEventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    
    // 滚动处理
    let scrollEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        // 是否返回原始事件 (不启用平滑时)
        var returnOriginalEvent = true
        // 判断输入源 (无法区分黑苹果, 因为黑苹果的触控板驱动直接模拟鼠标输入)
        // 当鼠标输入, 根据需要执行翻转方向/平滑滚动
        if ScrollUtils.shared.isMouse(of: event) {
            // 获取目标窗口 BundleId
            let targetBID = ScrollUtils.shared.getBundleIdFromMouseLocation(and: event)
            // 获取列表中应用程序的列外设置信息
            let exceptionalApplications = ScrollUtils.shared.applicationInExceptionalApplications(bundleId: targetBID)
            // 是否翻转
            let enableReverse = ScrollUtils.shared.enableReverse(application: exceptionalApplications)
            // 是否平滑
            let enableSmooth = ScrollUtils.shared.enableSmooth(application: exceptionalApplications)
            // 处理滚动事件
            let scrollEvent = ScrollEvent(with: event)
            // Y轴
            if scrollEvent.Y.usable {
                // 是否翻转滚动
                if enableReverse {
                    ScrollEventUtils.reverseY(scrollEvent)
                }
                // 是否平滑滚动
                if enableSmooth {
                    // 禁止返回原始事件
                    returnOriginalEvent = false
                    // 如果输入值为非 Fixed 类型, 则使用 Step 作为门限值将数据归一化
                    if !scrollEvent.Y.fixed {
                        ScrollEventUtils.normalizeY(scrollEvent, Options.shared.advanced.step)
                    }
                }
            }
            // X轴
            if scrollEvent.X.usable {
                // 是否翻转滚动
                if enableReverse {
                    ScrollEventUtils.reverseX(scrollEvent)
                }
                // 是否平滑滚动
                if enableSmooth {
                    // 禁止返回原始事件
                    // returnOriginalEvent = false
                    returnOriginalEvent = true
                    // 如果输入值为非 Fixed 类型, 则使用 Step 作为门限值将数据归一化
                    if !scrollEvent.X.fixed {
                        ScrollEventUtils.normalizeX(scrollEvent, Options.shared.advanced.step)
                    }
                }
            }
            // 触发滚动事件推送
            if enableSmooth {
                ScrollCore.shared.updateScrollBuffer(y: scrollEvent.Y.usableValue, x: scrollEvent.X.usableValue)
                ScrollCore.shared.enableScrollEventPoster()
            }
        }
        // 返回事件对象
        if returnOriginalEvent {
            return Unmanaged.passUnretained(event)
        } else {
            return nil
        }
    }
    
    // 热键处理
    let hotkeyEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        var toggleKey = Options.shared.advanced.toggle
        var disableKey = Options.shared.advanced.block
        var keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // 统一左右 Shift 的 keyCode
        keyCode = keyCode==60 ? 56 : keyCode
        // 判断转换键
        if toggleKey != 0 && keyCode == toggleKey {
            ScrollCore.shared.toggleScroll = !ScrollCore.shared.toggleScroll
        }
        // 判断禁用键
        if disableKey != 0 && keyCode == disableKey {
            ScrollCore.shared.blockSmooth = !ScrollCore.shared.blockSmooth
            ScrollCore.shared.scrollBuffer = ScrollCore.shared.scrollCurr
        }
        return nil
    }
    
    
    // 启动滚动处理
    func startHandlingScroll() {
        // 开始截取事件
        scrollEventInterceptor = Interceptor.start(
            event: scrollEventMask,
            handleBy: scrollEventCallBack,
            listenOn: .cghidEventTap,
            placeAt: .tailAppendEventTap,
            for: .defaultTap
        )
        hotkeyEventInterceptor = Interceptor.start(
            event: hotkeyEventMask,
            handleBy: hotkeyEventCallBack,
            listenOn: .cghidEventTap,
            placeAt: .tailAppendEventTap,
            for: .listenOnly
        )
        // 初始化滚动事件发送器
        initScrollEventPoster()
        // 初始化守护进程
        tapKeeperTimer = Timer.scheduledTimer(
            timeInterval: 2.0,
            target: self,
            selector: #selector(tapKeeper),
            userInfo: nil,
            repeats: true
        )
    }
    // 停止滚动处理
    func endHandlingScroll() {
        // 停止守护进程
        tapKeeperTimer?.invalidate()
        // 停止滚动事件发送器
        disableScrollEventPoster()
        // 停止截取事件
        Interceptor.stop(scrollEventInterceptor)
        Interceptor.stop(hotkeyEventInterceptor)
    }
    // 守护进程
    // 在某些高压环境下 eventTap 会挂掉
    // 使用守护进程监控, 如果挂掉就重启, 监控周期 2S, 对CPU基本无占用
    @objc func tapKeeper() {
        if let ref = scrollEventInterceptor {
            if let tap = ref.eventTap {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
        }
        if let ref = hotkeyEventInterceptor {
            if let tap = ref.eventTap {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
        }
    }
        
    // 鼠标数据输入
    func updateScrollBuffer(y: Double, x: Double) {
        let speed = Options.shared.advanced.speed
        // 更新 Y 轴数据
        if y*scrollDelta.y > 0 {
            scrollBuffer.y += speed * y
        } else {
            scrollBuffer.y = speed * y
            scrollCurr.y = 0.0
        }
        // 更新 X 轴数据
        if x*scrollDelta.x > 0 {
            scrollBuffer.x += speed * x
        } else {
            scrollBuffer.x = speed * x
            scrollCurr.x = 0.0
        }
        scrollDelta = ( y: y, x: x )
    }
    
    // 鼠标插值数据输出
    // 初始化 CVDisplayLink
    func initScrollEventPoster() {
        // 新建一个 CVDisplayLinkSetOutputCallback 来执行循环
        CVDisplayLinkCreateWithActiveCGDisplays(&scrollEventPoster)
        CVDisplayLinkSetOutputCallback(scrollEventPoster!, {
            (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in ScrollCore.shared.handleScroll()
            return kCVReturnSuccess
        }, nil)
    }
    // 启动事件发送器
    func enableScrollEventPoster() {
        if !CVDisplayLinkIsRunning(scrollEventPoster!) {
            CVDisplayLinkStart(scrollEventPoster!)
        }
    }
    // 停止事件发送器
    func disableScrollEventPoster() {
        if let poster = scrollEventPoster {
            CVDisplayLinkStop(poster)
        }
    }
    
    // 根据需要变换滚动方向
    func weapScrollWhenToggling(y: Double, x: Double, toggling: Bool) -> (y: Double, x: Double) {
        // 如果按下 Shift, 则始终将滚动转为横向
        if toggling {
            // 判断哪个轴有值, 有值则赋给 X
            // 某些鼠标 (MXMaster/MXAnywhere), 按下 Shift 后会显式转换方向为横向, 此处针对这类转换进行归一化处理
            if y != 0.0 {
                return (y: x, x: y)
            } else {
                return (y: y, x: x)
            }
        } else {
            return (y: y, x: x)
        }
    }
    // 处理滚动事件
    func handleScroll() {
        // 计算插值
        let scrollPulse = (
            y: Interpolator.lerp(src: scrollCurr.y, dest: scrollBuffer.y),
            x: Interpolator.lerp(src: scrollCurr.x, dest: scrollBuffer.x)
        )
        // 更新滚动位置
        scrollCurr = (
            y: scrollCurr.y + scrollPulse.y,
            x: scrollCurr.x + scrollPulse.x
        )
        // 填入 scrollFiller, 并获取值
        let filteredValue = scrollFiller.fillIn(with: scrollPulse)
        // 变换滚动结果
        let swapedValue = weapScrollWhenToggling(y: filteredValue.y, x: filteredValue.x, toggling: toggleScroll)
        // 发送滚动结果
        MouseEvent.scroll(axis.YX, yScroll: Int32(swapedValue.y), xScroll: Int32(swapedValue.x))
        // 如果临近目标距离小于精确度门限则停止滚动
        if scrollPulse.y.magnitude<=Options.shared.advanced.precision && scrollPulse.x.magnitude<=Options.shared.advanced.precision {
            disableScrollEventPoster()
            scrollFiller.clean()
        }
    }
    
}
