#
#
#''' Sends messages in LINE BY LINE from json file using multiple PROCESSES. uStarts producers all at the same time.... doesnt actually start them at same time still'''
#
#
#
#import time
#import json
#import os
#from multiprocessing import Process
#from kafka import KafkaProducer
#
#KAFKA_BROKER = '10.0.0.210:29092'
#TOPIC_NAME = 'docker_topic_1'
#NUM_PRODUCERS = 10
#
#def init_producer():
#    return KafkaProducer(
#        bootstrap_servers=KAFKA_BROKER,
#        value_serializer=lambda v: json.dumps(v).encode('utf-8'),
#        linger_ms= 5,
#        batch_size= 327680 ,
#        buffer_memory=512000000, 
#        acks=1,
#        max_in_flight_requests_per_connection=20
#    )
#
#def send_file(filepath):
#    print(f" started [PID {os.getpid()}]", time.time())
#    delay_time = time.time()
#    
#    producer = init_producer()
#
#    print(f"[PID {os.getpid()}] Starting send: {os.path.basename(filepath)},", time.time())
#
#    start_time = time.time()
#    actual_send_time = round(time.time() - delay_time, 2)
#    print('Subtract this from start time :', actual_send_time)
#    with open(filepath, 'r') as f:
#        for line in f:
#            if line.strip():
#                data = json.loads(line)
##                print(data)
#                producer.send(TOPIC_NAME, value=data)
#                #producer.send(TOPIC_NAME, value=data, timestamp_ms=int(int(data['datetime']) // 1_000_000))
#                #print(int(int(data['datetime']) // 1_000_000))
#
#    producer.flush()
#    producer.close()
#
#    total_time = round(time.time() - start_time, 2)
#    print('end_time =', time.time())
#    print(f"[PID {os.getpid()}] Finished {os.path.basename(filepath)} in {total_time} sec.")
#
#if __name__ == '__main__':
#    base_path = r"S:\2023_data_datetime_first_column_upload_test\test_upload_3_split\10_chunks_json_datetime_price_quantity_as_int"
#    filepaths = [os.path.join(base_path, f"test_file_part_{i}.json") for i in range(NUM_PRODUCERS)]
#
#    #filepaths = r'S:\2023_data_datetime_first_column_upload_test\json_file_price_as_int'
#    processes = []
#
#    #  Create and start all processes
#    for fp in filepaths:
#        p = Process(target=send_file, args=(fp,))
#        processes.append(p)
#
#    #time.sleep(1)  #  Let all processes initialize and wait at start_event
#    
#    for pro in processes:
#        pro.start()
#          
#    start_time = time.time()
#        
#    print('started')
#    
#    #  Wait for all to finish
#    for p in processes:
#        p.join()
#        print("joined")
#          
#    total_time = round(time.time() - start_time, 2)
#    print("total time = ", total_time)
#          
          
#########################################################
        
import os
import json
import time
from multiprocessing import Process
from kafka import KafkaProducer

# CONFIG
KAFKA_BROKER = '10.0.0.210:29092'
TOPIC_NAME = 'docker_topic_1'
BASE_PATH = r'S:\2023_data_datetime_first_column_upload_test\combine_json_data'
NUM_PROCESSES = 1

def init_producer():
    return KafkaProducer(
        bootstrap_servers=KAFKA_BROKER,
        value_serializer=lambda v: v.encode('utf-8'),
        linger_ms=5,
        batch_size=327680,
        buffer_memory=512000000,
        acks=1,
        max_in_flight_requests_per_connection=20
    )

def send_files(file_list, worker_id):
    producer = init_producer()
    total_sent = 0
    start_time = time.time()

    for filepath in file_list:
        filename = os.path.basename(filepath)
        print(f"[Worker {worker_id}] Sending file: {filename}")
        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if line:
                    producer.send(TOPIC_NAME, value=line)
                    total_sent += 1

    producer.flush()
    producer.close()
    duration = round(time.time() - start_time, 2)
    print(f"[Worker {worker_id}]  Done. Sent {total_sent} messages in {duration} sec.")

def split_list(lst, n):
    """Splits list `lst` into `n` roughly equal chunks."""
    k, m = divmod(len(lst), n)
    return [lst[i*k + min(i, m):(i+1)*k + min(i+1, m)] for i in range(n)]

if __name__ == "__main__":
    all_files = sorted([
        os.path.join(BASE_PATH, f)
        for f in os.listdir(BASE_PATH)
        if f.endswith(".json")
    ])

    chunks = split_list(all_files, NUM_PROCESSES)
    processes = []

    for i in range(NUM_PROCESSES):
        p = Process(target=send_files, args=(chunks[i], i))
        p.start()
        processes.append(p)

    for p in processes:
        p.join()

    print(" All files have been sent.")
