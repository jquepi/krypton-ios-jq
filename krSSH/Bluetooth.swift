//
//  Bluetooth.swift
//  Kryptonite
//
//  Created by Kevin King on 9/12/16.
//  Copyright © 2016 KryptCo, Inc. All rights reserved.
//

import Foundation
import CoreBluetooth

let krsshCharUUID = CBUUID(string: "20F53E48-C08D-423A-B2C2-1C797889AF24")

class BluetoothDelegate : NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var allServiceUUIDS : Set<CBUUID> = Set()
    var scanningServiceUUIDS: Set<CBUUID> = Set()
    var pairedServiceUUIDS: Set<CBUUID> = Set()

    var discoveredPeripherals : Set<CBPeripheral> = Set()
    var pairedPeripherals: [CBUUID: CBPeripheral] = [:]
    var peripheralCharacteristics: [CBPeripheral: CBCharacteristic] = [:]
    var knownPeripherals: Cache<NSString>? = try? Cache<NSString>(name: "BLUETOOTH_PERIPHERALS")
    var triedKnownPeripherals: Cache<NSString>? = try? Cache<NSString>(name: "TRIED_BLUETOOTH_PERIPHERALS")
    var recentPeripheralConnections: Cache<NSString>? = try? Cache<NSString>(name: "TRIED_BLUETOOTH_PERIPHERALS_CONNECT")


    var characteristicMessageBuffers: [CBCharacteristic: Data] = [:]
    var serviceQueuedMessage: [CBUUID: NetworkMessage] = [:]

    var mutex : Mutex = Mutex()
    var central: CBCentralManager?
    var silo: Silo?

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        mutex.lock()
        defer{ mutex.unlock() }
        self.central = central
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in restoredPeripherals {
                peripheral.delegate = self
                guard let services = peripheral.services else {
                    continue
                }
                for service in services {
                    guard let characteristics = service.characteristics else {
                        continue
                    }
                    for characteristic in characteristics {
                        if characteristic.uuid == krsshCharUUID {
                            pairedPeripherals[service.uuid] = peripheral
                            pairedServiceUUIDS.insert(service.uuid)
                            allServiceUUIDS.insert(service.uuid)
                            peripheralCharacteristics[peripheral] = characteristic
                        }
                    }
                }
            }
        }
    }

    func writeToServiceUUID(uuid: CBUUID, message: NetworkMessage) {
        mutex.lock()
        defer { mutex.unlock() }
        let data = message.networkFormat()
        
        guard let peripheral = pairedPeripherals[uuid],
            let characteristic = peripheralCharacteristics[peripheral] else {
                serviceQueuedMessage[uuid] = message
            return
        }
        do {
            let messageBlocks = try splitMessageForBluetooth(message: data, mtu: UInt(peripheral.maximumWriteValueLength(for: .withResponse)))
            for block in messageBlocks {
                peripheral.writeValue(block, for: characteristic, type: .withResponse)
            }
            log("sent BT response")
        } catch let e {
            log("bluetooth message split failed: \(e)", .error)
        }
    }

    func scanLogic() {
        guard let central = central else {
            return
        }
        if central.state != .poweredOn {
            if central.isScanning {
                central.stopScan()
            }
            scanningServiceUUIDS.removeAll()
            pairedServiceUUIDS.removeAll()
            return
        }

        let shouldBeScanning = allServiceUUIDS.subtracting(pairedServiceUUIDS)
        if shouldBeScanning.count == 0 {
            if central.isScanning {
                log("Stop scanning")
                central.stopScan()
            }
            return
        }

        scanningServiceUUIDS = shouldBeScanning

        for matchingPeripheral in central.retrieveConnectedPeripherals(withServices: Array(allServiceUUIDS)) {
            if !pairedPeripherals.values.contains(matchingPeripheral) {
                log("found unpaired connected peripheral with services \(matchingPeripheral.services)")
                discoveredPeripherals.insert(matchingPeripheral)
                connectPeripheral(central, matchingPeripheral)
            }
        }

        if let knownPeripherals = knownPeripherals,
            let triedKnownPeripherals = triedKnownPeripherals {
            knownPeripherals.removeExpiredObjects()
            triedKnownPeripherals.removeExpiredObjects()
            let uuids = knownPeripherals.allObjects().filter({
                triedKnownPeripherals.object(forKey: $0 as String) == nil
            }).flatMap { UUID(uuidString: $0 as String) }
            log("checking \(uuids.count) known peripherals")

            for knownPeripheral in central.retrievePeripherals(withIdentifiers: uuids) {
                if !pairedPeripherals.values.contains(knownPeripheral) {
                    triedKnownPeripherals.setObject(knownPeripheral.identifier.uuidString as NSString, forKey: knownPeripheral.identifier.uuidString, expires: .seconds(3600))
                    log("found unpaired known peripheral with services \(knownPeripheral.services)")
                    discoveredPeripherals.insert(knownPeripheral)
                    connectPeripheral(central, knownPeripheral)
                }
            }
        }

        log("Scanning for \(scanningServiceUUIDS)")
        central.scanForPeripherals(withServices: Array(scanningServiceUUIDS), options:nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        mutex.lock()
        defer { mutex.unlock() }
        log("CBCentral state \(central.state.rawValue)")
        if central.state == .poweredOn {
            self.central = central
            log("CBCentral poweredOn")
        }
        scanLogic()
    }

    func addServiceUUID(uuid: CBUUID) {
        mutex.lock()
        defer { mutex.unlock() }

        if allServiceUUIDS.contains(uuid) {
             log("already had uuid \(uuid.uuidString)")
            return
        }

        log("add uuid \(uuid.uuidString)")
        allServiceUUIDS.insert(uuid)
        triedKnownPeripherals?.removeAllObjects()
        scanLogic()
    }

    func removeServiceUUID(uuid: CBUUID) {
        mutex.lock()
        defer { mutex.unlock() }
        removeServiceUUIDLocked(uuid: uuid)
    }

    func removeServiceUUIDLocked(uuid: CBUUID) {
        if !allServiceUUIDS.contains(uuid) {
            log("didn't have uuid \(uuid.uuidString) in allServiceUUIDS")
        } else {
            log("remove uuid \(uuid.uuidString)")
        }
        allServiceUUIDS.remove(uuid)
        pairedServiceUUIDS.remove(uuid)
        scanningServiceUUIDS.remove(uuid)
        if let pairedPeripheral = pairedPeripherals.removeValue(forKey: uuid) {
            //  Check if any remaining serviceUUIDs for peripheral
            if !pairedPeripherals.values.contains(pairedPeripheral) {
                central?.cancelPeripheralConnection(pairedPeripheral)
            }
        }
        serviceQueuedMessage.removeValue(forKey: uuid)
        scanLogic()
    }

    func refreshServiceUUID(uuid: CBUUID) {
        mutex.lock()
        defer { mutex.unlock() }
        log("refresh uuid \(uuid.uuidString)")
        removeServiceUUIDLocked(uuid: uuid)
        allServiceUUIDS.insert(uuid)
        triedKnownPeripherals?.removeAllObjects()
        scanLogic()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        mutex.lock()
        defer { mutex.unlock() }
        log("Discovered \(peripheral.name) at RSSI \(RSSI)")
        //  keep reference so not GCed
        discoveredPeripherals.insert(peripheral)

        connectPeripheral(central, peripheral)

    }

    func connectPeripheral(_ central: CBCentralManager, _ peripheral: CBPeripheral) {
        if let recentPeripheralConnections = recentPeripheralConnections {
            recentPeripheralConnections.removeExpiredObjects()
            if recentPeripheralConnections.object(forKey: peripheral.identifier.uuidString) != nil {
                return
            }
            recentPeripheralConnections.setObject("", forKey: peripheral.identifier.uuidString, expires: .seconds(10))
        }

        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        mutex.lock()
        defer { mutex.unlock() }
        log("connected \(peripheral.identifier)")
        peripheral.delegate = self
        peripheral.discoverServices(Array(allServiceUUIDS))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        mutex.lock()
        defer { mutex.unlock() }
        log("failed to connect \(peripheral.identifier)")
        discoveredPeripherals.remove(peripheral)
        recentPeripheralConnections?.removeObject(forKey: peripheral.identifier.uuidString)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        mutex.lock()
        defer { mutex.unlock() }
        guard let services = peripheral.services else {
            return
        }
        var foundPairedServiceUUID = false
        for service in services {
            guard allServiceUUIDS.contains(service.uuid) else {
                continue
            }
            foundPairedServiceUUID = true
            log("discovered service UUID \(service.uuid)")
            pairedPeripherals[service.uuid] = peripheral
            pairedServiceUUIDS.insert(service.uuid)
            scanningServiceUUIDS.remove(service.uuid)
            peripheral.discoverCharacteristics([krsshCharUUID], for: service)
        }
        if !foundPairedServiceUUID {
            log("disconnected peripheral with no relevant services \(peripheral.identifier.uuidString)")
            central?.cancelPeripheralConnection(peripheral)
        }
        scanLogic()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?){
        mutex.lock()
        defer { mutex.unlock() }

        guard let chars = service.characteristics else {
            log("service has no characteristics")
            return
        }

        guard allServiceUUIDS.contains(service.uuid) else {
            log("found characterisics for unpaired service \(service.uuid)")
            return
        }
        for char in chars {
            guard char.uuid.isEqual(krsshCharUUID) else {
                log("found non-krSSH characteristic \(char.uuid)")
                continue
            }
            log("discovered krSSH characteristic")
            peripheralCharacteristics[peripheral] = char
            peripheral.setNotifyValue(true, for: char)
            knownPeripherals?.setObject(peripheral.identifier.uuidString as NSString, forKey: peripheral.identifier.uuidString, expires: .seconds(3600*24*14))
            if let queuedMessage = serviceQueuedMessage.removeValue(forKey: service.uuid) {
                dispatchAsync {
                    self.writeToServiceUUID(uuid: service.uuid, message: queuedMessage)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        mutex.lock()
        defer { mutex.unlock() }
        if let error = error {
            log("Error changing notification state: \(error.localizedDescription)", .error)
        }

        guard characteristic.uuid.isEqual(krsshCharUUID) else {
            return
        }

        if (characteristic.isNotifying) {
            log("Notification began on \(characteristic)")
        } else {
            log("Notification stopped on (\(characteristic))  Disconnecting")
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            log("Error reading characteristic: \(error!.localizedDescription)", .error)
            return
        }

        guard let data = characteristic.value else {
            return
        }
        log("read \(data.count) bytes from \(peripheral.identifier)")
        mutex.lock {
            onUpdateCharacteristicValue(characteristic: characteristic, data: data)
        }
    }

    //  precondition: mutex locked
    func onUpdateCharacteristicValue(characteristic: CBCharacteristic, data: Data) {
        if data.count == 0 {
            return
        }
        let n = data[0]
        log("n: \(n)")
        let data = data.subdata(in: 1..<data.count)
        if characteristicMessageBuffers[characteristic] != nil {
            characteristicMessageBuffers[characteristic]!.append(data)
        } else {
            characteristicMessageBuffers[characteristic] = data
        }
        if n == 0 {
            // buffer complete
            if let fullBuffer = characteristicMessageBuffers.removeValue(forKey: characteristic) {
                log("reconstructed full message of length \(fullBuffer.count)")
                if let silo = silo {
                    //  onBluetoothReceive locks mutex
                    mutex.unlock()
                    do {
                        let message = try NetworkMessage(networkData: fullBuffer)
                        try silo.onBluetoothReceive(serviceUUID: characteristic.service.uuid, message: message)
                    } catch (let e) {
                        log("error processing bluetooth message: \(e)")
                    }
                    mutex.lock()
                } else {
                    log("BluetoothDelegate Silo not set", .error)
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        mutex.lock()
        defer { mutex.unlock() }
        log("Peripheral \(peripheral.identifier) disconnected")
        for disconnectedUUID in pairedPeripherals.filter({ $0.1 == peripheral }).map({$0.0}) {
            log("service uuid disconnected \(disconnectedUUID)")
            pairedPeripherals.removeValue(forKey: disconnectedUUID)
            pairedServiceUUIDS.remove(disconnectedUUID)
        }
        recentPeripheralConnections?.removeObject(forKey: peripheral.identifier.uuidString)
        scanLogic()
    }
}

struct BluetoothMessageTooLong : Error {
    var messageLength : Int
    var mtu : Int
}
/*
 *  Bluetooth packet protocol: first byte of message indicates number of 
 *  remaining packets. Packets must be <= mtu in length.
 */
func splitMessageForBluetooth(message: Data, mtu: UInt) throws -> [Data] {
    let msgBlockSize = mtu - 1;
    let (intN, overflow) = UInt.divideWithOverflow(UInt(message.count), msgBlockSize)
    if overflow || intN > 255 {
        throw BluetoothMessageTooLong(messageLength: message.count, mtu: Int(mtu))
    }
    var blocks : [Data] = []
    let n: UInt8 = UInt8(intN)
    var offset = Int(0)
    for n in (0...n).reversed() {
        var block = Data()
        var inoutN = n
        block.append(&inoutN, count: 1)
        let endIndex = min(message.count, offset + Int(msgBlockSize))
        block.append(message.subdata(in: offset..<endIndex))

        blocks.append(block)
        offset += Int(msgBlockSize)
    }
    return blocks
}
